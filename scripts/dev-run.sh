#!/usr/bin/env bash
#
# dev-run.sh — run/stop the devcontainer WITHOUT VS Code.
#
# Mirrors .devcontainer/devcontainer.json's container config exactly:
#   - image:  ghcr.io/arekglinka/lambda_cpp26-dev:latest   (override: IMAGE=...)
#   - name:   lambda_cpp26-dev                             (override: DEV_CONTAINER_NAME=...)
#   - GPU:    --device=/dev/dxg + read-only bind mount of /usr/lib/wsl
#             (both skipped gracefully with a [warn] when /dev/dxg is absent
#             → CPU-only mode)
#   - workspace: $REPO_ROOT → /workspaces/lambda_cpp26 (:Z SELinux relabel,
#             working dir set there)
#   - ports:  8888 (jupyter) and 8501 (streamlit) — reachable from the Windows
#             browser via WSL2 localhost-forwarding at http://localhost:8888
#             and http://localhost:8501
#   - env:    PYTHONPATH=/workspaces/lambda_cpp26/build/Release:/workspaces/lambda_cpp26
#             (mirrors remoteEnv)
#             LD_LIBRARY_PATH=<pip-nvidia cu13 lib>:/usr/lib/wsl/lib:/opt/gcc16/lib64
#             (pip-nvidia dir FIRST — torch/jax otherwise starve cupy's NVRTC
#             loads; image ENV is overridden by -e so it's restated here)
#             XLA_PYTHON_CLIENT_PREALLOCATE=false (jax grabs 75% VRAM otherwise)
#   - user:   root (mirrors remoteUser)
#   - entrypoint: sleep infinity (Lambda RIE base — the --entrypoint override
#             is MANDATORY, else the container treats the command as a handler
#             and exits immediately)
#
# Usage:
#   scripts/dev-run.sh up       # create + start (idempotent)
#   scripts/dev-run.sh down     # stop (container kept for fast restart)
#   scripts/dev-run.sh status   # running/stopped/absent + image id
#   scripts/dev-run.sh -h       # this help
#
# The container is never removed by this script — 'down' only stops it so the
# next 'up' is a fast start. Remove by hand: podman rm -f lambda_cpp26-dev
#
set -euo pipefail

GH_USER="${GH_USER:-arekglinka}"
IMAGE="${IMAGE:-ghcr.io/${GH_USER}/lambda_cpp26-dev:latest}"
DEV_CONTAINER_NAME="${DEV_CONTAINER_NAME:-lambda_cpp26-dev}"
CONTAINER_WS="/workspaces/lambda_cpp26"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

log()  { printf '\033[1;34m[dev-run]\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m[ok]\033[0m   %s\n' "$*"; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n' "$*"; }
err()  { printf '\033[1;31m[err]\033[0m  %s\n' "$*" >&2; }
die()  { err "$*"; exit 1; }

usage() {
    cat <<EOF
Usage: scripts/dev-run.sh <up|down|status>
  up       create + start the dev container (idempotent; GPU if /dev/dxg present)
  down     stop the dev container (container kept for fast restart)
  status   show running/stopped/absent + image id
Env:
  DEV_CONTAINER_NAME=...  container name (default: lambda_cpp26-dev)
  IMAGE=...               image ref (default: ghcr.io/$GH_USER/lambda_cpp26-dev:latest)
Ports: 8888 (jupyter) + 8501 (streamlit) → http://localhost:8888 / :8501
       (WSL2 localhost-forwarding reaches the Windows browser)
EOF
}

require_podman() {
    command -v podman >/dev/null 2>&1 || die "podman not found on PATH."
}

image_id() {
    podman image inspect -f '{{.Id}}' "$IMAGE" 2>/dev/null || true
}

container_state() {
    # echoes exactly one of: running | stopped | absent
    if ! podman container exists "$DEV_CONTAINER_NAME" 2>/dev/null; then
        echo "absent"
    elif [[ "$(podman inspect -f '{{.State.Running}}' "$DEV_CONTAINER_NAME")" == "true" ]]; then
        echo "running"
    else
        echo "stopped"
    fi
}

gpu_flags() {
    # Mirrors devcontainer.json runArgs. No /dev/dxg → skip BOTH flags
    # gracefully (CPU-only mode); never fail the container over them.
    GPU_FLAGS=()
    if [[ -e /dev/dxg ]]; then
        GPU_FLAGS+=(--device=/dev/dxg)
        if [[ -d /usr/lib/wsl ]]; then
            GPU_FLAGS+=(--mount=type=bind,src=/usr/lib/wsl,dst=/usr/lib/wsl,readonly)
        else
            warn "/usr/lib/wsl missing — passing GPU device without WSL driver libs."
        fi
        ok "GPU passthrough flags enabled (/dev/dxg)."
    else
        warn "/dev/dxg absent — CPU-only mode (skipping GPU device + /usr/lib/wsl mount)."
    fi
}

banner() {
    printf '\n'
    log "Quick use:"
    log "  shell:     make dev-exec"
    log "  jupyter:   jupyter lab --ip=0.0.0.0 --no-browser   (in-container)"
    log "  streamlit: streamlit run <app>.py                   (in-container)"
    log "  URLs:      http://localhost:8888 (jupyter)  http://localhost:8501 (streamlit)"
    log "             (WSL2 localhost-forwarding — reachable from the Windows browser)"
    printf '\n'
}

cmd_up() {
    require_podman
    local state
    state="$(container_state)"
    case "$state" in
        running)
            ok "Container ${DEV_CONTAINER_NAME} already running."
            ;;
        stopped)
            log "Starting existing container ${DEV_CONTAINER_NAME}..."
            podman start "$DEV_CONTAINER_NAME" >/dev/null
            ok "Started ${DEV_CONTAINER_NAME}."
            ;;
        absent)
            if [[ -z "$(image_id)" ]]; then
                die "Image ${IMAGE} not local — run 'make dev-up' first (pulls with retries + smoke test)."
            fi
            log "Creating container ${DEV_CONTAINER_NAME} (mirrors .devcontainer/devcontainer.json)..."
            gpu_flags
            # LD_LIBRARY_PATH: pip-nvidia cu13 dir goes FIRST — torch/jax preload
            # their bundled NVRTC and starve cupy's lazy kernel compiles
            # (libnvrtc-builtins.so.13.0 dlopen failure) otherwise. -e overrides
            # the image ENV, so the image's own entries are restated explicitly.
            podman run -d --name "$DEV_CONTAINER_NAME" \
                ${GPU_FLAGS[@]+"${GPU_FLAGS[@]}"} \
                --user root \
                -v "${REPO_ROOT}:${CONTAINER_WS}:Z" \
                -w "${CONTAINER_WS}" \
                -p 8888:8888 \
                -p 8501:8501 \
                -e PYTHONPATH="${CONTAINER_WS}/build/Release:${CONTAINER_WS}" \
                -e LD_LIBRARY_PATH="/var/lang/lib/python3.14/site-packages/nvidia/cu13/lib:/usr/lib/wsl/lib:/opt/gcc16/lib64" \
                -e XLA_PYTHON_CLIENT_PREALLOCATE=false \
                --entrypoint sleep \
                "$IMAGE" \
                infinity
            ok "Created + started ${DEV_CONTAINER_NAME}."
            ;;
    esac
    banner
    ok "Dev container up: ${DEV_CONTAINER_NAME} (${IMAGE})"
}

cmd_down() {
    require_podman
    local state
    state="$(container_state)"
    case "$state" in
        absent)  ok "Container ${DEV_CONTAINER_NAME} absent — nothing to stop." ;;
        running)
            log "Stopping ${DEV_CONTAINER_NAME} (container kept)..."
            podman stop "$DEV_CONTAINER_NAME" >/dev/null
            ok "Stopped ${DEV_CONTAINER_NAME} (restart with: scripts/dev-run.sh up)."
            ;;
        stopped) ok "Container ${DEV_CONTAINER_NAME} already stopped." ;;
    esac
}

cmd_status() {
    require_podman
    local state iid
    state="$(container_state)"
    iid="$(image_id)"
    [[ -n "$iid" ]] || iid="(absent)"
    printf '%-10s %s\n' "${DEV_CONTAINER_NAME}:" "$state"
    printf '%-10s %s\n' "image:" "$iid"
    if [[ "$state" == "running" ]]; then
        printf '%-10s %s\n' "exec:" "make dev-exec"
    fi
}

case "${1:-}" in
    up)        shift; cmd_up "$@" ;;
    down)      shift; cmd_down "$@" ;;
    status)    shift; cmd_status "$@" ;;
    -h|--help) usage; exit 0 ;;
    "")        usage >&2; die "Missing subcommand (up|down|status)" ;;
    *)         usage >&2; die "Unknown subcommand: $1" ;;
esac
