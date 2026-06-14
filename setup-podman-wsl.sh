#!/usr/bin/env bash
#
# setup-podman-wsl.sh — Configure Podman (rootful) + VSCode DevContainers on Ubuntu WSL2
#
# Target: Ubuntu (any version with systemd support, 22.04+ recommended) under WSL2.
# Mode:   Rootful Podman (system-wide socket at /run/podman/podman.sock).
#
# Usage:
#   chmod +x setup-podman-wsl.sh
#   ./setup-podman-wsl.sh
#
# Safe to re-run. Existing settings.json keys are preserved.
#
set -euo pipefail

# --- Pretty output -----------------------------------------------------------
log()  { printf '\033[1;34m[setup]\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m[ok]\033[0m   %s\n' "$*"; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[err]\033[0m  %s\n' "$*" >&2; exit 1; }

# --- Pre-flight checks -------------------------------------------------------
[[ "$(id -u)" -eq 0 ]] && die "Run as your normal user, not root. The script will sudo when needed."

# WSL detection: /proc/sys/kernel/osrelease contains "microsoft" or "Microsoft"
if ! grep -qi microsoft /proc/sys/kernel/osrelease 2>/dev/null; then
    warn "Not running inside WSL (no 'microsoft' in kernel release). Continuing anyway."
fi

if ! grep -qiE '^NAME="?Ubuntu' /etc/os-release 2>/dev/null; then
    die "This script targets Ubuntu. Detected: $(grep -E '^NAME=' /etc/os-release 2>/dev/null || echo 'unknown')."
fi

log "Detected Ubuntu WSL2. Starting Podman + DevContainers setup."

# --- 1. Ensure systemd is enabled in WSL ------------------------------------
WSL_CONF=/etc/wsl.conf
ensure_systemd() {
    if grep -qE "^\[boot\]" "$WSL_CONF" 2>/dev/null && \
       grep -qE "^systemd=true" "$WSL_CONF" 2>/dev/null; then
        ok "systemd already enabled in /etc/wsl.conf."
        return
    fi
    log "Enabling systemd in ${WSL_CONF} (required for systemctl-based socket)."
    sudo tee -a "$WSL_CONF" >/dev/null <<'EOF'

[boot]
systemd=true
EOF
    warn "systemd was just enabled. After this script finishes, run from Windows:"
    warn "    wsl --shutdown"
    warn "Then reopen your WSL terminal and re-run this script to continue."
    ok "Re-run after WSL restart; the script will skip this step next time."
    exit 0
}

if pidof systemd >/dev/null 2>&1; then
    ok "systemd is running as PID 1."
else
    ensure_systemd
fi

# --- 2. Install Podman + jq -------------------------------------------------
if command -v podman >/dev/null 2>&1; then
    ok "podman already installed: $(podman --version)"
else
    log "Installing Podman via apt..."
    sudo apt-get update -y
    sudo apt-get install -y podman jq
    ok "podman installed: $(podman --version)"
fi

command -v jq >/dev/null 2>&1 || sudo apt-get install -y jq

# --- 3. Enable + start rootful podman.socket ---------------------------------
log "Enabling rootful podman.socket (systemd unit)..."
sudo systemctl enable --now podman.socket

# Verify the socket
SOCKET_PATH=/run/podman/podman.sock
if [[ -S "$SOCKET_PATH" ]]; then
    ok "Socket present: ${SOCKET_PATH}"
else
    die "Socket not found at ${SOCKET_PATH}. Check: sudo systemctl status podman.socket"
fi

# Probe Docker-compatible API: Podman v5 uses /v5.0.0, v4 uses /v4.0.0
if command -v curl >/dev/null 2>&1; then
    if curl -s --unix-socket "$SOCKET_PATH" http://localhost/v5.0.0/libpod/info >/dev/null 2>&1; then
        ok "Podman socket responds to API calls."
    else
        if curl -sf --unix-socket "$SOCKET_PATH" http://localhost/v4.0.0/libpod/info >/dev/null 2>&1; then
            ok "Podman socket responds (v4 API)."
        else
            warn "Socket exists but API did not respond. May still work for DevContainers — try opening the project."
        fi
    fi
fi

# --- 4. Smoke-test podman itself --------------------------------------------
log "Testing podman with a tiny container pull..."
if podman pull quay.io/podman/hello:latest >/dev/null 2>&1; then
    ok "podman pull works."
    podman rm -q "$(podman create quay.io/podman/hello:latest 2>/dev/null)" >/dev/null 2>&1 || true
else
    warn "podman pull failed — check network/DNS inside WSL."
fi

# --- 5. Configure VSCode settings (Machine scope, WSL side) ------------------
# When using Windows VSCode + Remote-WSL extension, settings for the DevContainers
# extension must live in the WSL filesystem. Machine-scope settings file:
VSCODE_MACHINE_SETTINGS="$HOME/.vscode-server/data/Machine/settings.json"

write_vscode_setting() {
    local file="$1" key="$2" value="$3"
    mkdir -p "$(dirname "$file")"
    if [[ -f "$file" ]]; then
        # Merge: only set the key if missing (preserve user values)
        if ! jq -e --arg k "$key" 'has($k)' "$file" >/dev/null 2>&1; then
            tmp=$(jq --arg k "$key" --argjson v "$value" '.[$k] = $v' "$file")
            echo "$tmp" > "$file"
            ok "Added '$key' to $file"
        else
            local existing
            existing=$(jq -r --arg k "$key" '.[$k]' "$file")
            if [[ "$existing" == "$value" ]]; then
                ok "'$key' already correct in $file"
            else
                warn "'$key' exists with value '$existing' — leaving as-is (manually review if DevContainers fails)."
            fi
        fi
    else
        echo "{\"$key\": $value}" | jq '.' > "$file"
        ok "Created $file with '$key'"
    fi
}

log "Configuring VSCode Machine settings (WSL side)..."
write_vscode_setting "$VSCODE_MACHINE_SETTINGS" "docker.dockerPath"          '"podman"'
write_vscode_setting "$VSCODE_MACHINE_SETTINGS" "docker.host"               "\"unix://${SOCKET_PATH}\""
write_vscode_setting "$VSCODE_MACHINE_SETTINGS" "remote.containers.dockerPath" '"podman"'

REPO_SETTINGS="$(pwd)/.vscode/settings.json"
if [[ -d "$(pwd)/.devcontainer" ]]; then
    log "Found .devcontainer/ in $(pwd) — also writing workspace settings."
    write_vscode_setting "$REPO_SETTINGS" "docker.dockerPath"          '"podman"'
    write_vscode_setting "$REPO_SETTINGS" "docker.host"               "\"unix://${SOCKET_PATH}\""
    write_vscode_setting "$REPO_SETTINGS" "remote.containers.dockerPath" '"podman"'
fi

# --- 6. Summary --------------------------------------------------------------
cat <<EOF

Setup complete.

What was done:
  1. systemd enabled in /etc/wsl.conf   (skip if already configured)
  2. podman + jq installed
  3. rootful podman.socket enabled at ${SOCKET_PATH}
  4. VSCode settings written to:
       - ${VSCODE_MACHINE_SETTINGS}
       - ${REPO_SETTINGS}   (workspace, if .devcontainer present)

Next steps:
  1. In Windows VSCode, install extensions:
       - ms-vscode-remote.remote-containers
       - ms-vscode-remote.remote-wsl        (if not already)
  2. Open this folder via "Remote-WSL: Open Folder in WSL"
  3. Run command:  "Dev Containers: Reopen in Container"
  4. First build takes ~30+ minutes (GCC 16 compiled from source).

WSL2 resource hint for the GCC build:
  Create %USERPROFILE%\\.wslconfig on Windows with:
     [wsl2]
     memory=12GB
     processors=8
  Then:  wsl --shutdown   (reopen terminal to apply)

If the DevContainer build fails, check:
  - Socket:   sudo systemctl status podman.socket
  - Podman:   podman version && podman info
  - VSCode:   Output panel -> "Dev Containers" channel
EOF

unset VSCODE_MACHINE_SETTINGS REPO_SETTINGS SOCKET_PATH
