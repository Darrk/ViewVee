# ViewVee shared coturn fallback server

ViewVee maintains this infrastructure for both ViewVee and BabyWave.

Deploy this directory on a dedicated non-AWS VPS with a public IPv4 address.
It is independent from the Go signaling process: only sessions that cannot
form a direct ICE path send encrypted WebRTC media through this machine.

## Setup

1. Point `turn.viewvee.com` at the VPS public IP.
2. Copy `turnserver.conf.example` to `turnserver.conf` and replace all
   `CHANGE_ME` values. Use a cryptographically random shared secret of at least
   32 characters.
3. Put exactly the same secret in ViewVee API's `TURN_SHARED_SECRET` and,
   if BabyWave also uses this Coturn server, its `Config:TurnSettings:SharedSecret`.
   Never put the secret in Flutter, the signaling server, or source control.
4. Open TCP and UDP 3478, TCP 443 when TLS is configured, and UDP
   49160–49260 in both provider and host firewalls.
5. From `api/turn-server`, start with `docker compose up -d`.
6. Configure the existing BabyWave API (environment-variable form shown):

   ```sh
   Config__TurnSettings__Urls__0=turn:turn.viewvee.com:3478?transport=udp
   Config__TurnSettings__Urls__1=turn:turn.viewvee.com:3478?transport=tcp
   Config__TurnSettings__SharedSecret=<same-secret-as-turnserver.conf>
   Config__TurnSettings__CredentialTtlSeconds=86400
   ```

For restrictive corporate/mobile networks, provision a valid certificate,
mount it as shown in `docker-compose.yml`, uncomment `cert`/`pkey`, and add
`Config__TurnSettings__Urls__2=turns:turn.viewvee.com:443?transport=tcp`.

ViewVee fetches temporary credentials from its authenticated
`GET /api/turn/credentials` endpoint before every new internet peer connection,
including reconnects. Configure the API's `TURN_URLS` with the public client URL,
for example `turns:turn.viewvee.com:443?transport=tcp` when HAProxy forwards public
443 to Coturn TLS 5349. See [API deployment](../README.md).

When using HAProxy TLS passthrough, keep the certificate loaded by Coturn. Its
`external-ip` must identify the public address serving Coturn's UDP relay range,
which can differ from the load balancer's address. Certificate renewal must
preserve Coturn's read access and reload/restart Coturn.

`../../build.sh turn` publishes the ViewVee TURN image to ECR. The Compose
deployment defaults to the upstream coturn image; set `TURN_IMAGE` to the
published image to deploy that build.

## Production notes

- Host networking is intentional. TURN relays UDP over a port range and Docker
  port mapping performs poorly for large ranges.
- WebRTC media is already protected by DTLS-SRTP, including while it traverses
  TURN. Coturn forwards packets but does not terminate the WebRTC media layer.
- Monitor bandwidth, allocations, packet loss and provider egress cost. Set
  provider budget alerts and lower `total-quota` until actual capacity is known.
- BabyWave's temporary credentials are issued by its existing bearer-authenticated
  `/api/turn/credentials` endpoint. Keep normal API and coturn edge limits in
  place to contain compromised-account abuse.
- Keep UDP available for quality. TURN over TCP/TLS is a compatibility fallback
  and can have worse latency under packet loss.
