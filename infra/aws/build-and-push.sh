#!/usr/bin/env bash
# Build both service images and push them to ECR, tagged by git SHA.
#
# The tag is the commit and nothing else — no :latest, and the ECR repositories are
# IMMUTABLE — so a running task definition always names an image that can be traced
# back to exactly one tree, and a rollback is a task-definition change rather than a
# rebuild.
#
#   ./build-and-push.sh                 # builds HEAD
#   PROFILE=numo REGION=us-east-1 ./build-and-push.sh
set -euo pipefail

PROFILE="${PROFILE:-numo}"
REGION="${REGION:-us-east-1}"
STACK="${STACK:-numo-exchange}"

cd "$(dirname "$0")/../.."
ROOT="$(pwd)"

if ! git diff --quiet || ! git diff --cached --quiet; then
  echo "refusing to build: the working tree is dirty, so the SHA would not describe the image" >&2
  exit 1
fi

GIT_SHA="$(git rev-parse --short=12 HEAD)"
ACCOUNT="$(aws sts get-caller-identity --profile "$PROFILE" --query Account --output text)"
REGISTRY="${ACCOUNT}.dkr.ecr.${REGION}.amazonaws.com"

echo "==> building ${GIT_SHA} into ${REGISTRY}"

aws ecr get-login-password --region "$REGION" --profile "$PROFILE" \
  | docker login --username AWS --password-stdin "$REGISTRY"

# services/markets builds from its own directory; services/execution needs the
# repository root because it resolves @numo/abis through the pnpm workspace.
docker build \
  --platform linux/amd64 \
  --build-arg "GIT_SHA=${GIT_SHA}" \
  -t "${REGISTRY}/${STACK}/markets:${GIT_SHA}" \
  "${ROOT}/services/markets"

docker build \
  --platform linux/amd64 \
  --build-arg "GIT_SHA=${GIT_SHA}" \
  -f "${ROOT}/services/execution/Dockerfile" \
  -t "${REGISTRY}/${STACK}/execution:${GIT_SHA}" \
  "${ROOT}"

docker push "${REGISTRY}/${STACK}/markets:${GIT_SHA}"
docker push "${REGISTRY}/${STACK}/execution:${GIT_SHA}"

cat <<EOF

pushed ${GIT_SHA}

  terraform apply \\
    -var="image_markets=${REGISTRY}/${STACK}/markets:${GIT_SHA}" \\
    -var="image_execution=${REGISTRY}/${STACK}/execution:${GIT_SHA}"
EOF
