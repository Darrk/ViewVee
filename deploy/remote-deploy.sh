#!/usr/bin/env bash
set -euo pipefail
# Usage: remote-deploy.sh <folder> <image> <deploy|check> <port/health_path> <registry_user> <compose_service> <proxy_container>
# Run over SSH on the web host; the GHCR token is read from REGISTRY_TOKEN.
folder=$1
image=$2
mode=$3
health=$4
registry_user=$5
app_service=$6
proxy_container=$7
cd "$HOME/docker-files/$folder"
umask 077
exec 9>.viewvee-deploy.lock
flock -w 60 9
release_dir=$(mktemp -d "$PWD/.viewvee-deploy-XXXXXX")
previous_image=
changed=false

docker_cmd() {
  sudo -n env APP_IMAGE="$image" docker --config "$release_dir/registry" "$@"
}
compose() {
  docker_cmd compose --project-directory "$PWD" \
    -f "$release_dir/compose.yml" -f "$release_dir/image.yml" "$@"
}
# A per-project nginx proxy resolves the app's hostname only at startup, so
# reload it (or start it) after every app replacement. "-" means none: a shared
# host nginx reaches the app through its published port and needs no reload.
refresh_proxy() {
  [[ "$proxy_container" == - ]] && return 0
  compose up -d --no-recreate
  docker_cmd exec "$proxy_container" nginx -s reload || docker_cmd restart "$proxy_container"
}
set_image() {
  printf 'services:\n  %s:\n    image: "%s"\n' "$app_service" "$1" > "$release_dir/image.yml"
}
cleanup() {
  result=$?
  trap - EXIT
  if [[ "$result" != 0 && "$changed" == true ]]; then
    if [[ -n "$previous_image" ]]; then
      echo 'Deployment failed; restoring previous application image.' >&2
      set_image "$previous_image"
      { compose up -d --no-deps --wait --wait-timeout 120 "$app_service" && refresh_proxy; } ||
        echo 'Container rollback failed; inspect this node.' >&2
    else
      compose stop "$app_service" || true
    fi
  fi
  # Includes resolved runtime configuration and temporary GHCR authentication.
  rm -rf -- "$release_dir"
  exit "$result"
}
trap cleanup EXIT

# Write the registry auth directly instead of `docker login`: a host credential
# helper (e.g. pass/gpg) would store it where sudo Docker cannot decrypt it.
mkdir "$release_dir/registry"
registry_auth=$(printf '%s:%s' "$registry_user" "$REGISTRY_TOKEN" | base64 -w0)
printf '{"auths":{"ghcr.io":{"auth":"%s"}}}\n' "$registry_auth" > "$release_dir/registry/config.json"
unset REGISTRY_TOKEN registry_auth

# Preserve existing Compose env, networks, volumes, ports and project identity.
# config resolves relative bind mounts before writing the temporary snapshot.
services=$(docker_cmd compose config --services)
if ! grep -qxF "$app_service" <<<"$services"; then
  printf 'No "%s" service in %s; found: %s\n' "$app_service" "$PWD" "$(tr '\n' ' ' <<<"$services")" >&2
  exit 1
fi
docker_cmd compose config > "$release_dir/compose.yml"
set_image "$image"
compose pull "$app_service"
if [[ "$mode" == check ]]; then
  command -v curl >/dev/null
  exit 0
fi
container=$(compose ps --all --quiet "$app_service")
if [[ -n "$container" ]]; then
  previous_image=$(docker_cmd inspect --format '{{.Config.Image}}' "$container")
fi
changed=true
compose up -d --no-deps --wait --wait-timeout 120 "$app_service"
container=$(compose ps --quiet "$app_service")
if [[ "$health" == running ]]; then
  # Coturn uses host networking and has no HTTP endpoint.
  [[ "$(docker_cmd inspect --format '{{.State.Running}}' "$container")" == true ]]
  sleep 3
  [[ "$(docker_cmd inspect --format '{{.State.Running}}' "$container")" == true ]]
  changed=false
  printf 'Running: %s\n' "$image"
  exit 0
fi
# Probe the app on its Compose network when it has an address; otherwise use
# the published host port (e.g. HAProxy terminating TLS in front of 4785->80).
health_url=
for ip in $(docker_cmd inspect --format '{{range .NetworkSettings.Networks}}{{.IPAddress}} {{end}}' "$container"); do
  health_url="http://$ip:${health%%/*}/${health#*/}"
  break
done
if [[ -z "$health_url" ]]; then
  published=$(compose port "$app_service" "${health%%/*}" 2>/dev/null | head -n 1 || true)
  if [[ -n "$published" ]]; then
    health_url="http://127.0.0.1:${published##*:}/${health#*/}"
  fi
fi
if [[ -z "$health_url" ]]; then
  echo 'Application container has no network address.' >&2
  exit 1
fi
for attempt in {1..30}; do
  if curl --fail --silent --max-time 5 "$health_url" >/dev/null; then
    refresh_proxy
    changed=false
    printf 'Healthy: %s\n' "$image"
    exit 0
  fi
  sleep 2
done
printf 'Application health check failed: %s\n' "$health_url" >&2
curl --fail --silent --show-error --max-time 5 "$health_url" >/dev/null || true
exit 1
