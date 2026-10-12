#!/usr/bin/env bash

set -euo pipefail

readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}"

readonly AWS_REGION="${AWS_REGION:-eu-central-1}"
readonly AWS_ACCOUNT_ID="${AWS_ACCOUNT_ID:-139685415139}"
readonly ECR_REGISTRY="${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"
readonly ECR_REPOSITORY="${ECR_REPOSITORY:-specterint/viewvee-web}"
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

aws ecr get-login-password --region "${AWS_REGION}" \
  | docker login --username AWS --password-stdin "${ECR_REGISTRY}"

build_and_push() {
  local repository="$1"
  local context="$2"
  local image="${ECR_REGISTRY}/${repository}"

  aws ecr describe-repositories \
    --region "${AWS_REGION}" \
    --repository-names "${repository}" >/dev/null 2>&1 \
    || aws ecr create-repository \
      --region "${AWS_REGION}" \
      --repository-name "${repository}" >/dev/null

  docker buildx build \
    --platform "${PLATFORMS:-linux/amd64,linux/arm64}" \
    --cache-from "type=registry,ref=${image}:cache" \
    --cache-to "type=registry,ref=${image}:cache,mode=max" \
    --tag "${image}:${IMAGE_TAG}" \
    --file "${context}/Dockerfile" \
    --push \
    "${context}"

  echo "Published ${image}:${IMAGE_TAG}"
}

for service in "$@"; do
  case "${service}" in
    web) build_and_push "${ECR_REPOSITORY}" api ;;
    signaling) build_and_push "${SIGNAL_ECR_REPOSITORY:-specterint/viewvee-signal}" api/signaling-server ;;
    turn) build_and_push "${TURN_ECR_REPOSITORY:-specterint/viewvee-turn}" api/turn-server ;;
  esac
done
