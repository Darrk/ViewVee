# Server CI and deployment

`.github/workflows/deploy.yml` runs server tests on pull requests and pushes.
Every push to `main` (including a merged pull request) tests the API and signaling,
builds all three multi-architecture images, publishes `latest` and the immutable
`sha-<commit>` tags to GHCR, and deploys the commit tags. Run the workflow manually
on `main` to retry. Production deployments are serialized.

All jobs use `[self-hosted, linux, x64]` runners. The deployment runner needs
network access to all hosts and a GitHub `production` environment. Fork pull
requests do not run code on these runners.
The `GITHUB_TOKEN` must have permission to publish and pull the existing
`ghcr.io/specterinteractive/viewvee-web`, `viewvee-signal`, and `viewvee-turn`
packages. Connect those packages to this repository or grant repository access in
GHCR. Set production secrets `EC2_SSH_PRIVATE_KEY` and `EC2_KNOWN_HOSTS` with an
SSH key authorized on all hosts and the verified host keys, respectively.

The existing production targets discovered on `ubuntu@10.0.0.3` are recorded in
[`production.conf`](production.conf). Set the optional `production` environment
variable `VIEWVEE_DEPLOY_TARGETS` to override the entire target list if the hosts
change. The format is:

```text
web|ubuntu@10.0.0.3|22|viewvee-web|8080/healthz|backend|viewvee-web-reverseproxy-1
signaling|ubuntu@10.0.0.3|22|viewvee-signal|8080/healthz|backend|viewvee-signal-reverseproxy-1
turn|ubuntu@10.0.0.3|22|viewvee-turn|running|coturn|-
```

Fields are service, SSH destination, port, folder under `~/docker-files/`,
container port/health path, Compose service, and nginx proxy container (`-` for
none). All three service types must be present; multiple targets are supported.
TURN uses `running` because
its host-networked container has no HTTP health endpoint. This verifies the
container stays running, not that TURN relay traffic succeeds.

Each folder must already contain its Compose project, configuration, credentials,
and persistent volumes. The web/API needs purchase credentials and a persistent
entitlement volume; TURN needs its existing `turnserver.conf`, certificates,
network, and firewall. Hosts need Docker Compose v2, passwordless `sudo docker`,
Bash, curl, and flock. The workflow validates all targets and pre-pulls every
image before replacing any container. It preserves the existing Compose settings,
checks web and signaling HTTP health, checks TURN container state, reloads the
specified proxy, and restores the previous image on a failed per-host deployment.
A failure after a previous target succeeded does not roll back other hosts.

The deploy uses a temporary Compose image override: the running container keeps the
new image, but later manual `docker compose up` without an image override can
restore the image declared in the host Compose file. Update the host Compose image
reference to the intended release when administering it manually.
