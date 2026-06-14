#!/usr/bin/env bash
#
# Build the devcontainer image from .devcontainer/Dockerfile and bake in the
# Conan dependency cache + project build (the equivalent of postCreateCommand,
# but committed into the image so teammates can pull instead of rebuild).
#
# Used by:
#   - .github/workflows/devcontainer.yml (CI publishes to ghcr.io)
#   - Local "rebuild from scratch" invocations when the Dockerfile/recipes change
#
# Requires: podman, ghcr.io login (already done in CI; locally run
#           `gh auth token | podman login ghcr.io -u <user> --password-stdin`).
#
set -euo pipefail

OWNER="${OWNER:-arekglinka}"
IMAGE="${IMAGE:-ghcr.io/${OWNER}/lambda_cpp26-dev}"
REGISTRY="${REGISTRY:-ghcr.io}"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

# Use short SHA + date for immutable tag, plus 'latest' mutable pointer.
SHORT_SHA="$(git rev-parse --short HEAD)"
DATE_TAG="$(date -u +%Y%m%d)"
TAG="${TAG:-${SHORT_SHA}}"

log()  { printf '\033[1;34m[build]\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m[ok]\033[0m   %s\n' "$*"; }
die()  { printf '\033[1;31m[err]\033[0m  %s\n' "$*" >&2; exit 1; }

command -v podman >/dev/null 2>&1 || die "podman not found on PATH."

BASE_IMAGE="localhost/lambda_cpp26-dev-base:${TAG}"

log "Building base image from .devcontainer/Dockerfile (GCC compile, ~25-30 min)..."
podman build \
    -f .devcontainer/Dockerfile \
    -t "$BASE_IMAGE" \
    .

# Run postCreateCommand-equivalent inside a temp container, then commit.
# This bakes ~/.conan2 (dep cache) + /tmp/conan-profiles + /tmp/recipes
# into the final image so teammates skip the entire dep-build phase.
PREP_CONTAINER="devcontainer-prep-${TAG}"
log "Creating prep container to bake Conan deps + project build..."
podman rm -f "$PREP_CONTAINER" 2>/dev/null || true
podman create --name "$PREP_CONTAINER" \
    -v "$REPO_ROOT:/workspaces/lambda_cpp26:Z" \
    -w /workspaces/lambda_cpp26 \
    "$BASE_IMAGE" \
    sleep infinity
podman start "$PREP_CONTAINER"

# Same command as the original devcontainer.json postCreateCommand, but
# runs against the bind-mounted workspace so artifacts land in the host tree
# only for THIS build — the committed image captures ~/.conan2 + system state,
# not the workspace (which is bind-mounted per-user at open time).
log "Running conan install + build inside prep container (~5-10 min with cache misses)..."
podman exec -it "$PREP_CONTAINER" bash -lc '
    set -euo pipefail
    cd /workspaces/lambda_cpp26
    conan install . --build=missing \
        -pr:h /tmp/conan-profiles/al2023 \
        -pr:b /tmp/conan-profiles/al2023 \
        -s:h build_type=Release
    conan build . \
        -pr:h /tmp/conan-profiles/al2023 \
        -pr:b /tmp/conan-profiles/al2023
'

log "Committing prep container as image..."
FINAL_IMAGE="${IMAGE}:${TAG}"
podman commit \
    --format oci \
    "$PREP_CONTAINER" \
    "$FINAL_IMAGE"
podman tag "$FINAL_IMAGE" "${IMAGE}:latest"
podman tag "$FINAL_IMAGE" "${IMAGE}:dev-${DATE_TAG}"

podman stop "$PREP_CONTAINER" >/dev/null
podman rm   "$PREP_CONTAINER" >/dev/null

ok "Built: ${FINAL_IMAGE}"
ok "Tagged: ${IMAGE}:latest, ${IMAGE}:dev-${DATE_TAG}"

if [[ "${PUSH:-1}" == "1" ]]; then
    log "Pushing to ${REGISTRY}..."
    podman push "${IMAGE}:${TAG}"
    podman push "${IMAGE}:latest"
    podman push "${IMAGE}:dev-${DATE_TAG}"
    ok "Pushed 3 tags to ${REGISTRY}"
fi

ok "Done. Teammates: git pull, then 'Reopen in Container' (image pull ~2-5 min)."
