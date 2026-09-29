#!/usr/bin/env bash
#
# Build the devcontainer image from the shared toolchain base + a thin
# .devcontainer/Dockerfile, baking the Conan cache + project build into the
# result so teammates pull instead of rebuild.
#
# Base resolution: the base image is built from 4 granular stages
# (toolchain → python → conan-deps → agents), each tagged with its own
# content hash. scripts/base-stage-hash.sh is the single source of truth for
# those hashes (this script, the Makefile and base-image.yml all call it).
# Each stage is resolved in order (sequential resolution primes the local
# layer cache for later stages):
#   1. pull ghcr.io/<owner>/lambda_cpp26-base:<hash>[-suffix]  (CI-produced, warm)
#   2. reuse a locally-built stage with the same tag
#   3. build it locally from Containerfile.base (slow: GCC compile)
# Only stages whose inputs change rebuild: recipe changes re-run just
# conan-deps + agents; bun/omo changes re-run only agents — GCC is never
# recompiled. The thin devcontainer FROMs the agents-stage hash.
#
# Used by:
#   - .github/workflows/devcontainer.yml (CI publishes to ghcr.io)
#   - local "rebuild from scratch" invocations when the Dockerfile/recipes change
#
# Requires: podman; ghcr.io login in CI (locally:
#           `gh auth token | podman login ghcr.io -u <user> --password-stdin`).
#
set -euo pipefail

OWNER="${OWNER:-arekglinka}"
IMAGE="${IMAGE:-ghcr.io/${OWNER}/lambda_cpp26-dev}"
BASE_IMAGE="${BASE_IMAGE:-ghcr.io/${OWNER}/lambda_cpp26-base}"
REGISTRY="${REGISTRY:-ghcr.io}"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

# Per-stage content hashes — the helper is the single sync point with the
# base-image workflow; no file list to keep in sync by hand.
H_TC="$(scripts/base-stage-hash.sh toolchain)"
H_PY="$(scripts/base-stage-hash.sh python-stack)"
H_CONAN="$(scripts/base-stage-hash.sh conan-deps)"
H_AG="$(scripts/base-stage-hash.sh agents)"

# Use short SHA + date for immutable tag, plus 'latest' mutable pointer.
SHORT_SHA="$(git rev-parse --short HEAD)"
DATE_TAG="$(date -u +%Y%m%d)"
TAG="${TAG:-${SHORT_SHA}}"

log()  { printf '\033[1;34m[build]\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m[ok]\033[0m   %s\n' "$*"; }
die()  { printf '\033[1;31m[err]\033[0m  %s\n' "$*" >&2; exit 1; }

command -v podman >/dev/null 2>&1 || die "podman not found on PATH."

# Resolve one stage tag: pull from registry → reuse local → build locally.
# Extra tags (e.g. :latest) are applied only on the local-build branch.
resolve_stage() {
    local target="$1" suffix="$2" hash="$3"
    shift 3
    local ref="${BASE_IMAGE}:${hash}${suffix}"
    local tag_args=()
    local t
    for t in "$@"; do tag_args+=( -t "$t" ); done
    if podman pull "$ref" > /dev/null 2>&1; then
        ok "Stage pulled from registry: ${ref}"
    elif podman image exists "$ref"; then
        ok "Stage already local: ${ref}"
    else
        if [[ "${ALLOW_LOCAL_STAGE_BUILD:-0}" != "1" ]]; then
            die "Stage ${ref} not found locally or in ${REGISTRY}.
Heavy base builds run in CI only (GCC/Arrow/QuantLib compiles stress this machine).
  -> Trigger CI: push to main, or: gh workflow run base-image.yml
  -> Local override (at your own risk): ALLOW_LOCAL_STAGE_BUILD=1 $0"
        fi
        log "Stage ${ref} not found — building locally from Containerfile.base (slow on cache miss; ALLOW_LOCAL_STAGE_BUILD=1)..."
        podman build \
            -f Containerfile.base \
            --target "$target" \
            -t "$ref" \
            ${tag_args[@]+"${tag_args[@]}"} \
            .
        ok "Stage built locally."
    fi
}

# Sequential: resolving stage N-1 primes the local layer cache for stage N.
resolve_stage toolchain    "-toolchain" "$H_TC"
resolve_stage python-stack "-python"    "$H_PY"
resolve_stage conan-deps   "-conan"     "$H_CONAN"
resolve_stage agents       ""           "$H_AG" "${BASE_IMAGE}:latest"

DEV_IMAGE="localhost/lambda_cpp26-dev-raw:${TAG}"

log "Building thin devcontainer image on ${BASE_IMAGE}:${H_AG}..."
podman build \
    -f .devcontainer/Dockerfile \
    --build-arg REGISTRY_OWNER="$OWNER" \
    --build-arg BASE_TAG="$H_AG" \
    -t "$DEV_IMAGE" \
    .

PREP_CONTAINER="devcontainer-prep-${TAG}"
log "Running conan install + build inside prep container (~5-10 min on cache miss)..."
podman rm -f "$PREP_CONTAINER" 2>/dev/null || true

# --entrypoint '[]' clears the Lambda base ENTRYPOINT (Lambda RIE), which would
# otherwise treat our command as a handler and exit immediately.
podman run --name "$PREP_CONTAINER" \
    --entrypoint '[]' \
    -v "$REPO_ROOT:/workspaces/lambda_cpp26:Z" \
    -w /workspaces/lambda_cpp26 \
    "$DEV_IMAGE" \
    bash -lc '
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

podman rm "$PREP_CONTAINER" >/dev/null
podman rmi "$DEV_IMAGE" > /dev/null

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
