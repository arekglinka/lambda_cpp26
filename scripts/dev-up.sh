#!/usr/bin/env bash
#
# dev-up.sh — one-command local devcontainer launcher.
#
# Pre-flights auth + machine resources, fixes the known VS Code podman trap
# (machine settings pointing docker.host at the permission-denied rootful
# socket /run/podman/podman.sock), pulls the ghcr dev image with retries and
# smoke-tests it. Resource gates abort BEFORE any bytes are pulled — two
# ~15 GB dev-image pulls OOM'd this WSL2 box in the past.
#
# Usage:
#   scripts/dev-up.sh                # full: pre-flight → prune offer → pull → smoke
#   scripts/dev-up.sh --check        # pre-flight only (steps 1-4), no pull
#   DEV_UP_YES=1 scripts/dev-up.sh   # auto-answer the dangling-image prune prompt
#
# Env overrides: GH_USER, IMAGE
#
set -euo pipefail

GH_USER="${GH_USER:-arekglinka}"
IMAGE="${IMAGE:-ghcr.io/${GH_USER}/lambda_cpp26-dev:latest}"
AUTH_JSON="${HOME}/.config/containers/auth.json"
VSC_SETTINGS="${HOME}/.vscode-server/data/Machine/settings.json"

log()  { printf '\033[1;34m[dev-up]\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m[ok]\033[0m   %s\n' "$*"; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n' "$*"; }
err()  { printf '\033[1;31m[err]\033[0m  %s\n' "$*" >&2; }
die()  { err "$*"; exit 1; }

usage() {
    cat <<'EOF'
Usage: scripts/dev-up.sh [--check]
  (no flag)  full run: pre-flight → dangling-prune offer → pull (3 retries) → smoke test
  --check    pre-flight only (gh auth, ghcr login, vscode settings, resource gates)
Env:
  DEV_UP_YES=1   auto-answer the dangling-image prune prompt (dangling only, never full prune)
  GH_USER=...    ghcr.io user (default: arekglinka)
  IMAGE=...      image ref (default: ghcr.io/$GH_USER/lambda_cpp26-dev:latest)
EOF
}

MODE="full"
case "${1:-}" in
    --check)   MODE="check" ;;
    "")        MODE="full" ;;
    -h|--help) usage; exit 0 ;;
    *)         usage >&2; die "Unknown option: $1" ;;
esac

# ---- PASS/FAIL table (printed in --check mode and on any pre-flight failure) ----
ROWS=()
print_table() {
    printf '\n%-6s %s\n' "STATUS" "CHECK"
    printf -- '-%.0s' {1..60}; printf '\n'
    local row status name
    for row in "${ROWS[@]}"; do
        status="${row%%|*}"
        name="${row#*|}"
        if [[ "$status" == "PASS" ]]; then
            printf '\033[1;32m%-6s\033[0m %s\n' "$status" "$name"
        else
            printf '\033[1;31m%-6s\033[0m %s\n' "$status" "$name"
        fi
    done
    printf '\n'
}

step() {
    local name="$1"
    shift
    if "$@"; then
        ROWS+=("PASS|$name")
        ok "$name"
    else
        ROWS+=("FAIL|$name")
        print_table
        die "PRE-FLIGHT FAILED at: $name"
    fi
}

# ---- Step 1: gh auth + packages scope ----
check_gh_auth() {
    command -v gh >/dev/null 2>&1 || { err "gh CLI not found on PATH."; return 1; }
    if ! gh auth status >/dev/null 2>&1; then
        err "Not logged in to GitHub. Run: gh auth login"
        return 1
    fi
    if ! gh auth status 2>&1 | grep -qE 'write:packages|read:packages'; then
        err "gh token lacks a packages scope (needed for ghcr.io pulls)."
        err "Create a PAT with write:packages: https://github.com/settings/tokens/new?description=ghcr-dev"
        err "Then: gh auth login  (paste the new token)"
        return 1
    fi
}

# ---- Step 2: podman login ghcr.io (idempotent) ----
check_podman_login() {
    command -v podman >/dev/null 2>&1 || { err "podman not found on PATH."; return 1; }
    if [[ -f "$AUTH_JSON" ]] && grep -q 'ghcr.io' "$AUTH_JSON" 2>/dev/null; then
        log "Already logged in to ghcr.io (${AUTH_JSON})"
        return 0
    fi
    log "Logging in to ghcr.io with gh token..."
    gh auth token | podman login ghcr.io -u "$GH_USER" --password-stdin >/dev/null || {
        err "podman login ghcr.io failed."
        return 1
    }
}

# ---- Step 3: VS Code machine settings fix (rootful-socket trap) ----
check_vscode_settings() {
    if [[ ! -f "$VSC_SETTINGS" ]]; then
        log "No VS Code machine settings at ${VSC_SETTINGS} — nothing to fix."
        log "If you create one later, set \"docker.dockerPath\": \"podman\" (never docker.host → /run/podman/podman.sock)."
        return 0
    fi
    command -v python3 >/dev/null 2>&1 || { warn "python3 not found — skipping VS Code settings check."; return 0; }

    local has_trap
    has_trap="$(python3 - "$VSC_SETTINGS" <<'PY'
import json, sys
try:
    with open(sys.argv[1]) as f:
        data = json.load(f)
except Exception:
    print("no")
    sys.exit(0)
host = data.get("docker.host")
print("yes" if isinstance(host, str) and "/run/podman/podman.sock" in host else "no")
PY
)"
    if [[ "$has_trap" != "yes" ]]; then
        log "VS Code settings: no dead docker.host → /run/podman/podman.sock entry."
        return 0
    fi

    local backup
    backup="${VSC_SETTINGS}.bak.$(date +%Y%m%d-%H%M%S)"
    cp "$VSC_SETTINGS" "$backup"
    python3 - "$VSC_SETTINGS" <<'PY'
import json, sys
path = sys.argv[1]
with open(path) as f:
    data = json.load(f)
removed = data.pop("docker.host", None)
data["docker.dockerPath"] = "podman"
with open(path, "w") as f:
    json.dump(data, f, indent=4, sort_keys=True)
    f.write("\n")
print(f"removed docker.host = {removed!r} (dead rootful socket); set docker.dockerPath = 'podman'")
PY
    ok "VS Code settings fixed (backup: ${backup})"
}

# ---- Step 4: resource gates (hard fail BEFORE any pull; hard fails in --check too) ----
check_resources() {
    local containers_parent disk_gb ram_gb failed=0
    containers_parent="$(dirname "${HOME}/.local/share/containers")"
    disk_gb="$(df --output=avail -B1G "$containers_parent" | tail -1 | tr -d ' ')"
    ram_gb="$(free -b | awk '/^Mem:/{print int($7/1073741824)}')"

    if [[ -z "$disk_gb" ]] || (( disk_gb < 30 )); then
        err "Disk: ${disk_gb:-?} GB free under ${containers_parent} — need >= 30 GB (dev image ~15 GB + layers)."
        failed=1
    fi
    if [[ -z "$ram_gb" ]] || (( ram_gb < 8 )); then
        err "RAM: ${ram_gb:-?} GB available — need >= 8 GB. Close memory-heavy apps first."
        failed=1
    fi
    if (( failed )); then
        err "Resource gates failed. Hints: close apps; reclaim disk with 'podman image prune -f' (dangling only — safe cleanup, never a full prune)."
        return 1
    fi
    log "Resources OK: ${disk_gb} GB disk free, ${ram_gb} GB RAM available."
}

# ---- Step 5 (full mode): safe cleanup offer — dangling images only ----
offer_cleanup() {
    if [[ "${DEV_UP_YES:-0}" == "1" ]]; then
        log "DEV_UP_YES=1 → pruning dangling images (never a full prune)..."
        podman image prune -f
        return 0
    fi
    local reply
    read -r -p "Prune dangling podman images before pulling? [y/N] " reply || reply=""
    if [[ "$reply" =~ ^[Yy]$ ]]; then
        podman image prune -f
    else
        log "Skipping prune."
    fi
}

# ---- Step 6 (full mode): pull with retries (ghcr 502s happen) ----
pull_image() {
    local attempt start elapsed
    start="$(date +%s)"
    for attempt in 1 2 3; do
        log "Pull attempt ${attempt}/3: ${IMAGE}"
        if podman pull "$IMAGE"; then
            elapsed=$(( $(date +%s) - start ))
            ok "Pulled in ${elapsed}s."
            return 0
        fi
        if (( attempt < 3 )); then
            warn "Pull failed (ghcr.io can 502). Retrying in 20s..."
            sleep 20
        fi
    done
    elapsed=$(( $(date +%s) - start ))
    err "Pull failed after 3 attempts (${elapsed}s)."
    return 1
}

# ---- Step 7 (full mode): smoke test. Lambda base ENTRYPOINT = RIE → the
# --entrypoint python3 override is MANDATORY or the container treats the
# command as a handler and exits immediately. ----
smoke_test() {
    log "Smoke test (Lambda RIE base → --entrypoint python3 override)..."
    if ! podman run --rm --entrypoint python3 "$IMAGE" -c \
        "import sys, torch, jax, polars, pandas, streamlit; print('python', sys.version.split()[0]); print('torch', torch.__version__, 'cuda', torch.cuda.is_available()); print('jax', jax.__version__); print('polars', polars.__version__)"; then
        err "Smoke test failed — image integrity problem."
        return 1
    fi
    ok "Smoke test passed."
    log "Note: torch.cuda.is_available() prints False without GPU runArgs — expected here (image-integrity check only); GPU activates via the devcontainer's runArgs."
}

# ---- Step 8 (full mode): GPU readiness ----
gpu_readiness() {
    if [[ -e /dev/dxg && -d /usr/lib/wsl/drivers ]]; then
        ok "GPU passthrough ready (/dev/dxg + /usr/lib/wsl/drivers present)."
    else
        warn "GPU passthrough not detected (missing /dev/dxg or /usr/lib/wsl/drivers) — devcontainer will start but CPU-only."
    fi
}

# ---- Step 9 (full mode): next steps ----
next_steps() {
    printf '\n'
    log "Next steps:"
    log "  1. VS Code: 'Dev Containers: Reopen in Container'"
    log "  2. Shell in:       make dev-exec"
    log "  3. Jupyter:        jupyter lab --ip=0.0.0.0 --no-browser"
    log "  4. GPU notebook:   notebooks/gpu_showcase.ipynb"
    printf '\n'
}

main() {
    log "Pre-flight (mode: ${MODE})..."
    step "gh auth + packages scope"              check_gh_auth
    step "podman login ghcr.io"                  check_podman_login
    step "vscode machine settings (docker.host)" check_vscode_settings
    step "resource gates (disk>=30G ram>=8G)"    check_resources

    if [[ "$MODE" == "check" ]]; then
        print_table
        ok "PRE-FLIGHT OK"
        return 0
    fi

    offer_cleanup
    pull_image || die "Image pull failed — nothing to smoke-test."
    smoke_test || die "Smoke test failed."
    gpu_readiness
    next_steps
    ok "Done — image ready: ${IMAGE}"
}

main
