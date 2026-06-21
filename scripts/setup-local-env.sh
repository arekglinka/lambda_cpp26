#!/usr/bin/env bash
# =============================================================================
# setup-local-env.sh — one-command local development environment setup.
#
# Run on the HOST after `git clone`. Does everything needed so you can
# immediately open the project in VSCode's dev container and debug C++
# breakpoints in pytest without building anything.
#
# What it does:
#   1. Verifies prerequisites (podman, socket, gh auth)
#   2. Pulls the CI-built devcontainer image from ghcr.io (~5 GB, one-time)
#   3. Pre-builds workspace artifacts (compile_commands.json + .so) inside
#      a temp container — takes ~2 min because all deps are cached in the image
#   4. Verifies the artifacts landed in the bind-mounted workspace
#   5. Prints next steps for VSCode
#
# Usage:
#   git clone <repo-url> lambda_cpp26
#   cd lambda_cpp26
#   ./scripts/setup-local-env.sh
#
# Prerequisites (one-time, per machine):
#   - podman installed
#   - podman user socket enabled:
#       systemctl --user enable --now podman.socket
#   - gh CLI authenticated with read:packages scope:
#       gh auth login
#       gh auth refresh -s read:packages
#   - VSCode with "Dev Containers" extension installed
#   - VSCode user settings configured for podman (the script checks and warns)
# =============================================================================
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IMAGE="ghcr.io/arekglinka/lambda_cpp26-dev:latest"
CONTAINER_NAME="lambda-cpp26-setup-$$"
WORKSPACE_DIR="/workspaces/$(basename "$REPO_ROOT")"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; NC='\033[0m'

info()  { echo -e "${CYAN}[INFO]${NC}  $*"; }
ok()    { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
err()   { echo -e "${RED}[ERR]${NC}   $*" >&2; }

echo ""
echo "============================================"
echo "  lambda_cpp26 — Local Environment Setup"
echo "============================================"
echo ""

# --- Step 1: Verify prerequisites -------------------------------------------

info "Checking prerequisites..."

command -v podman >/dev/null 2>&1 || {
    err "podman not found. Install: https://podman.io/getting-started/installation"
    exit 1
}
ok "podman $(podman --version | awk '{print $3}')"

UID_NUM="$(id -u)"
SOCKET="/run/user/${UID_NUM}/podman/podman.sock"
if [ ! -S "$SOCKET" ]; then
    err "Podman user socket not found at $SOCKET"
    err "Enable it:  systemctl --user enable --now podman.socket"
    exit 1
fi
ok "Podman socket active"

# Check VSCode user settings for podman config
VSCODE_SETTINGS="$HOME/.config/Code/User/settings.json"
if [ -f "$VSCODE_SETTINGS" ]; then
    if ! grep -q "dev.containers.dockerPath" "$VSCODE_SETTINGS" 2>/dev/null; then
        warn "VSCode user settings missing podman config. Add to $VSCODE_SETTINGS:"
        echo '  {'
        echo '    "dev.containers.dockerPath": "podman",'
        echo "    \"dev.containers.dockerSocketPath\": \"$SOCKET\""
        echo '  }'
        echo ""
    else
        ok "VSCode user settings have podman config"
    fi
else
    warn "VSCode user settings not found at $VSCODE_SETTINGS"
    warn "After first VSCode launch, add podman config manually."
fi

# --- Step 2: Authenticate to ghcr.io (if needed) ----------------------------

info "Checking ghcr.io authentication..."

# Try a pull to see if we're already authenticated
if podman pull "$IMAGE" 2>/dev/null; then
    ok "Already authenticated to ghcr.io"
else
    info "Need to authenticate. Trying gh CLI..."

    if command -v gh >/dev/null 2>&1; then
        GH_TOKEN="$(gh auth token 2>/dev/null || true)"
        GH_USER="$(gh api user --jq .login 2>/dev/null || true)"

        if [ -n "$GH_TOKEN" ] && [ -n "$GH_USER" ]; then
            echo "$GH_TOKEN" | podman login ghcr.io -u "$GH_USER" --password-stdin
            ok "Authenticated to ghcr.io as $GH_USER"
        else
            err "gh CLI not authenticated. Run: gh auth login && gh auth refresh -s read:packages"
            exit 1
        fi
    else
        err "gh CLI not found and not authenticated to ghcr.io."
        err "Either:"
        err "  1. Install gh CLI and run: gh auth login && gh auth refresh -s read:packages"
        err "  2. Manually: podman login ghcr.io -u <github-username> --password-stdin <<< <PAT>"
        exit 1
    fi

    # Retry the pull
    info "Pulling $IMAGE..."
    podman pull "$IMAGE" || {
        err "Pull failed even after authentication. Check your read:packages scope."
        exit 1
    }
fi
ok "Image pulled: $IMAGE ($(podman image inspect "$IMAGE" --format '{{.Size}}' 2>/dev/null | awk '{printf "%.1f GB", $1/1073741824}'))"

# --- Step 3: Pre-build workspace artifacts ----------------------------------

info "Pre-building workspace artifacts (compile_commands.json + .so)..."
info "This runs conan install + build inside the image. All deps are cached → ~2 min."

# Clean up any stale setup container
podman rm -f "$CONTAINER_NAME" 2>/dev/null || true

# Start temp container with workspace bind-mounted
podman run -d --entrypoint '[]' \
    --name "$CONTAINER_NAME" \
    -v "$REPO_ROOT:$WORKSPACE_DIR:Z" \
    -w "$WORKSPACE_DIR" \
    "$IMAGE" sleep 300 >/dev/null

# Run the bootstrap script inside the container
if ! podman exec -w "$WORKSPACE_DIR" "$CONTAINER_NAME" \
    ./scripts/bootstrap-workspace.sh 2>&1; then
    err "Workspace bootstrap failed."
    podman rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
    exit 1
fi

# --- Step 4: Verify artifacts -----------------------------------------------

info "Verifying workspace artifacts..."

CC_JSON="$REPO_ROOT/build/Release/compile_commands.json"
SO_GLOB="$REPO_ROOT/build/Release/sum_columns.cpython-*.so"

if [ -f "$CC_JSON" ]; then
    ok "compile_commands.json: $(stat -c%s "$CC_JSON") bytes"
else
    err "compile_commands.json not found at $CC_JSON"
    podman rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
    exit 1
fi

# shellcheck disable=SC2086
if ls $SO_GLOB 1>/dev/null 2>&1; then
    # shellcheck disable=SC2086
    SO_FILE="$(ls $SO_GLOB | head -1)"
    ok "pybind11 .so: $(basename "$SO_FILE") ($(stat -c%s "$SO_FILE" | awk '{printf "%.1f MB", $1/1048576}'))"
else
    err "sum_columns .so not found in build/Release/"
    podman rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
    exit 1
fi

# --- Step 5: Cleanup --------------------------------------------------------

podman rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true

# --- Done -------------------------------------------------------------------

echo ""
echo "============================================"
echo -e "  ${GREEN}Setup Complete!${NC}"
echo "============================================"
echo ""
echo "  Everything is pre-built. To start developing:"
echo ""
echo "  1. Open VSCode:"
echo "       code $REPO_ROOT"
echo ""
echo "  2. Command Palette (Ctrl+Shift+P):"
echo "       Dev Containers: Reopen in Container"
echo ""
echo "  3. VSCode will use the pre-pulled image (instant, no build)."
echo ""
echo "  4. After container opens, restart clangd:"
echo "       Ctrl+Shift+P → clangd: Restart language server"
echo ""
echo "  5. To debug C++ breakpoints in pytest:"
echo "       • Open src/sum_columns.cpp, set breakpoints"
echo "       • Run & Debug dropdown → 'Debug pytest (sum_columns module)'"
echo "       • Press F5"
echo ""
echo "  To rebuild the .so after C++ changes (inside container):"
echo "       make -C build/Release sum_columns -j\$(nproc)"
echo ""
