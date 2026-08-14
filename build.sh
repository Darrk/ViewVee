#!/usr/bin/env bash

set -euo pipefail

readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}"

readonly AWS_REGION="${AWS_REGION:-eu-central-1}"
readonly AWS_ACCOUNT_ID="${AWS_ACCOUNT_ID:-139685415139}"
readonly ECR_REGISTRY="${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"
readonly ECR_REPOSITORY="${ECR_REPOSITORY:-specterint/viewvee-web}"
readonly IMAGE="${ECR_REGISTRY}/${ECR_REPOSITORY}"
readonly IMAGE_TAG="${IMAGE_TAG:-latest}"

aws ecr describe-repositories \
  --region "${AWS_REGION}" \
  --repository-names "${ECR_REPOSITORY}" >/dev/null 2>&1 \
  || aws ecr create-repository \
    --region "${AWS_REGION}" \
    --repository-name "${ECR_REPOSITORY}" >/dev/null

aws ecr get-login-password --region "${AWS_REGION}" \
  | docker login --username AWS --password-stdin "${ECR_REGISTRY}"

docker buildx build \
  --platform "${PLATFORMS:-linux/amd64,linux/arm64}" \
  --cache-from "type=registry,ref=${IMAGE}:cache" \
  --cache-to "type=registry,ref=${IMAGE}:cache,mode=max" \
  --tag "${IMAGE}:${IMAGE_TAG}" \
  --file api/Dockerfile \
  --push \
  api

echo "Published ${IMAGE}:${IMAGE_TAG}"
