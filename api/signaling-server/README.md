# ViewVee shared Internet signaling relay

Maintained by ViewVee for both ViewVee and BabyWave. This service pairs one
transmitter with one receiver and forwards only WebRTC
setup messages. It does not implement TURN, media forwarding, recording, or
storage. BabyWave obtains optional TURN credentials from its existing
authenticated API; ViewVee currently receives TURN credentials at build time.
Media is relayed by the separately operated coturn host in `../turn-server`.

## Run

```sh
cd api/signaling-server
go test ./...
go run .
```

ViewVee defaults to `wss://signal.viewvee.com/viewvee/ws`; BabyWave uses
`wss://signal.viewvee.com/baby-monitor/ws`. For another ViewVee
environment, build Flutter with:

```sh
flutter build apk \
  --dart-define=VIEWVEE_SIGNALING_URL=wss://signal.example.com/viewvee/ws
```

TLS must terminate at a trusted reverse proxy or load balancer. Forward the
WebSocket upgrade and preserve the path. Both `/baby-monitor/ws` and
`/viewvee/ws` use the same signaling handler and shared rooms, so peers can
connect through either path. The process exposes
`GET /healthz` for health checks.

## Configuration

| Variable | Default | Purpose |
| --- | --- | --- |
| `ADDRESS` | `:8080` | Listen address |
| `ALLOWED_ORIGINS` | empty | Comma-separated browser Origin host patterns; native apps send no Origin |
| `MAX_CONNECTIONS` | `10000` | Global concurrent WebSocket cap |
| `MAX_CONNECTIONS_PER_IP` | `20` | Concurrent cap per source IP |
| `MAX_ROOMS` | `5000` | In-memory active room cap |
| `MAX_MESSAGES_PER_SECOND` | `100` | Per-connection signaling message cap |
| `READ_LIMIT_BYTES` | `270336` | Maximum inbound WebSocket message size |
| `REGISTRATION_TIMEOUT` | `10s` | Time allowed for the first registration frame |
| `WRITE_TIMEOUT` | `5s` | Per-message write/ping deadline |
| `PING_INTERVAL` | `20s` | Dead-connection detection interval |
| `TRUST_PROXY_HEADERS` | `false` | Trust the first `X-Forwarded-For` IP; enable only behind a proxy that overwrites it |

The relay is intentionally stateful and in-memory. Run one replica initially.
Horizontal scaling requires either session affinity keyed by the QR session ID
or a shared room/message backend; blindly adding replicas will split peers.

## Security and operating notes

- QR sessions use 128-bit random routing IDs. A separate 256-bit QR secret
  authenticates every relayed signaling envelope end-to-end and is never sent
  to this server.
- The six-digit code shown in the UI is display-only; it cannot join a session.
- Keep logs free of session IDs and payloads. The included server logs only
  lifecycle and role information.
- Put request-rate limiting and connection-rate limiting at the edge in
  addition to the process-level concurrent limits.
- Configure TURN credentials for each consuming app. With the separate
  [`../turn-server`](../turn-server) deployment,
  ICE uses direct candidates when possible and relays only failed direct paths.
