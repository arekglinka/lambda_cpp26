#!/usr/bin/env bash
#
# Commit the CURRENTLY RUNNING devcontainer and push it to ghcr.io.
#
# Use case: the container is already in a known-good state (deps built, project
# builds, tests pass) and you want to share that exact state with teammates
# without rebuilding from scratch.
#
# Prereq: ghcr.io login. Run once:
#     gh auth token | podman login ghcr.io -u <your-github-user> --password-stdin
#
set -euo pipefail

OWNER="${OWNER:-arekglinka}"
IMAGE="${IMAGE:-ghcr.io/${OWNER}/lambda_cpp26-dev}"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

SHORT_SHA="$(git rev-parse --short HEAD)"
DATE_TAG="$(date -u +%Y%m%d)"
TAG="${TAG:-${SHORT_SHA}}"

log()  { printf '\033[1;34m[push]\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m[ok]\033[0m   %s\n' "$*"; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[err]\033[0m  %s\n' "$*" >&2; exit 1; }

command -v podman >/dev/null 2>&1 || die "podman not found on PATH."

# Discover the running devcontainer.  VSCode names devcontainers as
# "vsc-<repo-hash>" or assigns a random adjective_noun name; either way the
# image starts with "localhost/vsc-lambda_cpp26-".
CONTAINER_NAME="${CONTAINER_NAME:-}"

if [[ -z "$CONTAINER_NAME" ]]; then
    log "Auto-detecting running devcontainer..."
    CONTAINER_NAME="$(podman ps --format '{{.Names}}' | grep -E '^(vsc-lambda_cpp26|[a-z]+_[a-z]+$)' | head -1 || true)"
    [[ -z "$CONTAINER_NAME" ]] && die "No running devcontainer found. Open the project in VSCode first, or set CONTAINER_NAME manually."
fi

log "Found container: ${CONTAINER_NAME}"
podman container inspect "$CONTAINER_NAME" --format 'Image: {{.Image}}{{"\n"}}Status: {{.State.Status}}{{"\n"}}Started: {{.State.StartedAt}}' >/dev/null

FINAL_IMAGE="${IMAGE}:${TAG}"
log "Committing ${CONTAINER_NAME} as ${FINAL_IMAGE}..."

# --format oci ensures compatibility with ghcr.io (Docker manifest format).
# --change preserves the original CMD/ENV/WORKDIR so the image opens correctly
# when teammates pull it via "Reopen in Container".
podman commit \
    --format oci \
    --change 'WORKDIR /workspace' \
    "$CONTAINER_NAME" \
    "$FINAL_IMAGE"

podman tag "$FINAL_IMAGE" "${IMAGE}:latest"
podman tag "$FINAL_IMAGE" "${IMAGE}:dev-${DATE_TAG}"

ok "Tagged:"
ok "  ${FINAL_IMAGE}"
ok "  ${IMAGE}:latest"
ok "  ${IMAGE}:dev-${DATE_TAG}"

# Show the size so the user knows what they're pushing (~4 GB expected).
SIZE="$(podman image inspect "$FINAL_IMAGE" --format '{{.Size}}' 2>/dev/null || echo 0)"
SIZE_HR="$(numfmt --to=iec "${SIZE}" 2>/dev/null || echo "${SIZE} bytes")"
ok "Image size: ${SIZE_HR}"

if [[ "${PUSH:-1}" == "1" ]]; then
    log "Pushing 3 tags to ghcr.io (this may take a while for ~4 GB)..."
    podman push "${IMAGE}:${TAG}"
    podman push "${IMAGE}:latest"
    podman push "${IMAGE}:dev-${DATE_TAG}"
    ok "Pushed.  Teammates pull on next 'Reopen in Container'."
else
    warn "PUSH=0 set — skipping push. Image is local only."
fi
