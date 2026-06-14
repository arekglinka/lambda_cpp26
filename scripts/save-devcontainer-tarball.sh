#!/usr/bin/env bash
#
# Export the devcontainer image to a tarball for airgapped / shared-drive
# distribution (alternative to ghcr.io when registry access isn't available).
#
# Produces: lambda_cpp26-dev-<tag>.tar (OCI-format, ~4 GB)
#
# Recipients load it with:
#     podman load -i lambda_cpp26-dev-<tag>.tar
#     # then either set IMAGE=... or update devcontainer.json's "image" field
#
set -euo pipefail

OWNER="${OWNER:-arekglinka}"
IMAGE="${IMAGE:-ghcr.io/${OWNER}/lambda_cpp26-dev}"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

SHORT_SHA="$(git rev-parse --short HEAD)"
DATE_TAG="$(date -u +%Y%m%d)"
TAG="${TAG:-${SHORT_SHA}}"

log()  { printf '\033[1;34m[save]\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m[ok]\033[0m   %s\n' "$*"; }
die()  { printf '\033[1;31m[err]\033[0m  %s\n' "$*" >&2; exit 1; }

command -v podman >/dev/null 2>&1 || die "podman not found on PATH."

# Source can be: a published image (default), a local image, or a running
# container (auto-committed on the fly).
SOURCE="${SOURCE:-${IMAGE}:${TAG}}"

OUT_FILE="${OUT_FILE:-lambda_cpp26-dev-${TAG}.tar}"

if podman image exists "$SOURCE" 2>/dev/null; then
    log "Exporting local image ${SOURCE}..."
elif podman container exists "$SOURCE" 2>/dev/null; then
    log "Committing running container '${SOURCE}' to image first..."
    podman commit --format oci "$SOURCE" "${IMAGE}:${TAG}"
    SOURCE="${IMAGE}:${TAG}"
else
    log "Pulling ${SOURCE} from registry..."
    podman pull "$SOURCE"
fi

# gzip compression roughly halves the file size at the cost of ~30% longer save
# time.  For a 4 GB image this is ~2 GB output vs ~5 min vs ~3 min — worth it.
log "Saving to ${OUT_FILE} (this takes a few minutes)..."
podman save --format oci-archive -o "${OUT_FILE}.tmp" "$SOURCE"
mv "${OUT_FILE}.tmp" "$OUT_FILE"

# Compress and checksum in parallel.
log "Compressing + checksumming..."
gzip -6 "${OUT_FILE}" &
GZIP_PID=$!
sha256sum "${OUT_FILE}" > "${OUT_FILE}.sha256" &
SHA_PID=$!
wait "$GZIP_PID" "$SHA_PID"

COMPRESSED="${OUT_FILE}.gz"
SIZE_HR="$(numfmt --to=iec "$(stat -c%s "$COMPRESSED")")"
ok "Wrote: ${COMPRESSED} (${SIZE_HR})"
ok "Wrote: ${OUT_FILE}.sha256"
echo
ok "Share both files. Recipient runs:"
ok "  sha256sum -c ${OUT_FILE##*/}.sha256   # verify integrity"
ok "  gunzip ${OUT_FILE##*/}.gz"
ok "  podman load -i ${OUT_FILE##*/}"
