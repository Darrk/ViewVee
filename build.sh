#!/usr/bin/env bash

set -euo pipefail

readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}"

# Images go to GitHub Container Registry. Log in beforehand with
# `docker login ghcr.io`, or set GHCR_USER and GHCR_TOKEN (write:packages).
readonly REGISTRY="${REGISTRY:-ghcr.io/specterinteractive}"
readonly REVISION="$(git rev-parse HEAD 2>/dev/null || echo unknown)"
readonly IMAGE_TAG="${IMAGE_TAG:-latest}"

# With no arguments, publish all infrastructure maintained by ViewVee.
# Pass web, signaling, and/or turn to publish selected services.
if (($# == 0)); then
  set -- web signaling turn
fi
for service in "$@"; do
  case "${service}" in
    web|signaling|turn) ;;
    *) echo "Usage: $0 [web|signaling|turn ...]" >&2; exit 2 ;;
  esac
done

if [[ -n "${GHCR_TOKEN:-}" ]]; then
  printf '%s' "${GHCR_TOKEN}" \
    | docker login ghcr.io --username "${GHCR_USER:?GHCR_USER is required}" --password-stdin
fi

build_and_push() {
  local name="$1"
  local context="$2"
  local image="${REGISTRY}/${name}"
  local cache=(--cache-from "type=registry,ref=${image}:cache" --cache-to "type=registry,ref=${image}:cache,mode=max")

  # A FROM-only image has no layers to cache; the missing :cache tag only adds noise.
  if [[ $(grep -cvE '^\s*(#|$)' "${context}/Dockerfile") == 1 ]]; then
    cache=()
  fi

  docker buildx build \
    --platform "${PLATFORMS:-linux/amd64,linux/arm64}" \
    "${cache[@]}" \
    --label "org.opencontainers.image.source=https://github.com/Darrk/ViewVee" \
    --label "org.opencontainers.image.revision=${REVISION}" \
    --tag "${image}:${IMAGE_TAG}" \
    --tag "${image}:sha-${REVISION}" \
    --file "${context}/Dockerfile" \
    --push \
    "${context}"

  echo "Published ${image}:${IMAGE_TAG}"
}

for service in "$@"; do
  case "${service}" in
    web) build_and_push viewvee-web api ;;
    signaling) build_and_push viewvee-signal api/signaling-server ;;
    turn) build_and_push viewvee-turn api/turn-server ;;
  esac
done
