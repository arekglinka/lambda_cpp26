#!/usr/bin/env bash
#
# install.sh — one-command HOST bootstrap for the lambda_cpp26 devcontainer.
#
# Idempotent. Safe to re-run. Covers everything README.md "GPU setup"
# documents, in enforced order:
#   1. Platform detect (WSL2 vs native Linux)
#   2. Base prereqs: podman + user socket, gh auth, disk/RAM gates
#   3. GPU (native Linux only):
#        a. driver as MATCHED PAIR (prebuilt Canonical-signed kernel module +
#           same-version userspace) incl. kernel headers for module assembly
#        b. live module swap if nouveau is idle (else: reboot notice)
#        c. nvidia-container-toolkit
#        d. CDI spec generate + scrub to 0.6.0 (podman 4.9 rejects 0.7.0)
#   4. Image pull via scripts/dev-up.sh (retries + smoke test)
#   5. GPU smoke test inside a throwaway container
#
# Usage:
#   ./scripts/install.sh             # full bootstrap (uses sudo where needed)
#   ./scripts/install.sh --check     # non-mutating pre-flight only
#
# Env overrides: GH_USER, IMAGE
#
set -euo pipefail

GH_USER="${GH_USER:-arekglinka}"
IMAGE="${IMAGE:-ghcr.io/${GH_USER}/lambda_cpp26-dev:latest}"
KVER="$(uname -r)"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

log()  { printf '\033[1;34m[install]\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m[ok]\033[0m      %s\n' "$*"; }
warn() { printf '\033[1;33m[warn]\033[0m    %s\n' "$*"; }
err()  { printf '\033[1;31m[err]\033[0m     %s\n' "$*" >&2; }
die()  { err "$*"; exit 1; }

MODE="full"
case "${1:-}" in
    --check) MODE="check" ;;
    "")      MODE="full" ;;
    -h|--help) sed -n '2,25p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)       die "Unknown option: $1 (use --check or no args)" ;;
esac

# ---------------------------------------------------------------------------
is_wsl() { grep -qi microsoft /proc/sys/kernel/osrelease 2>/dev/null; }

gpu_hw_present() {
    nvidia-smi -L >/dev/null 2>&1 && return 0
    command -v lspci >/dev/null 2>&1 && lspci -d 10de: 2>/dev/null | grep -q . && return 0
    return 1
}

# podman 4.9's CDI parser rejects CDI 0.7.0 fields ('additionalGids') —
# rewrite specs in place as 0.6.0.
scrub_cdi() {
    python3 - "$@" <<'EOF'
import sys, yaml
for p in sys.argv[1:]:
    try:
        spec = yaml.safe_load(open(p))
    except FileNotFoundError:
        continue
    spec["cdiVersion"] = "0.6.0"
    for d in spec.get("devices", []):
        d.get("containerEdits", {}).pop("additionalGids", None)
    spec.get("containerEdits", {}).pop("additionalGids", None)
    yaml.safe_dump(spec, open(p, "w"), sort_keys=False)
    print(f"scrubbed: {p}")
EOF
}

cdi_spec() {
    compgen -G "/etc/cdi/nvidia*.yaml" 2>/dev/null | head -1 || true
}

cdi_scrubbed() {
    local f
    for f in /etc/cdi/nvidia*.yaml /var/run/cdi/nvidia*.yaml; do
        [[ -f "$f" ]] || continue
        grep -q 'cdiVersion: 0.6.0' "$f" || return 1
    done
    return 0
}

# Driver branch whose prebuilt module exists for THIS kernel, userspace too.
pick_branch() {
    local br
    for br in 595 610 590 580 570; do
        if apt-cache show "linux-modules-nvidia-${br}-${KVER}" >/dev/null 2>&1 \
           && apt-cache show "nvidia-driver-${br}" >/dev/null 2>&1; then
            echo "$br"
            return 0
        fi
    done
    return 1
}

driver_pair_ok() {
    local modv usv short ko
    ko="/lib/modules/${KVER}/kernel/nvidia-${1}/nvidia.ko"
    modv="$(modinfo -F version "$ko" 2>/dev/null || true)"
    [[ -n "$modv" ]] || return 1
    usv="$(dpkg-query -W -f='${Version}' "nvidia-driver-${1}" 2>/dev/null \
        | grep -oE '^[0-9]+(\.[0-9]+)*' || true)"
    [[ -n "$usv" ]] || return 1
    short="$(echo "$usv" | cut -d. -f1,2)"
    [[ "$modv" == "$short" ]]
}

# CDI device id from the spec (skips the 'all' pseudo-device).
cdi_first_gpu_id() {
    local spec
    spec="$(cdi_spec)"
    [[ -n "$spec" ]] || return 1
    awk "/^devices:/{f=1;next} /^[a-zA-Z]/{f=0} f && /- name:/ {n=\$NF; gsub(/['\\\" ]/,\"\",n); print n}" "$spec" \
        | grep -vx all | head -1
}

# ---------------------------------------------------------------------------
log "Platform: $(is_wsl && echo "WSL2" || echo "native Linux"), kernel ${KVER}, mode: ${MODE}"

# --- Step 2: base prereqs ---------------------------------------------------
command -v podman >/dev/null 2>&1 || die "podman missing. sudo apt install podman"
command -v gh     >/dev/null 2>&1 || die "gh CLI missing. sudo apt install gh && gh auth login"
gh auth status >/dev/null 2>&1   || die "gh not authenticated. Run: gh auth login"

SOCKET="/run/user/$(id -u)/podman/podman.sock"
if [[ ! -S "$SOCKET" && "$MODE" == "full" ]]; then
    systemctl --user enable --now podman.socket 2>/dev/null || true
fi
[[ -S "$SOCKET" ]] || warn "Podman user socket not at $SOCKET — run: systemctl --user enable --now podman.socket"

disk_gb="$(df --output=avail -B1G ~/.local/share/containers 2>/dev/null | tail -1 | tr -d ' ' || true)"
ram_gb="$(free -b 2>/dev/null | awk '/^Mem:/{print int($7/1073741824)}')"
[[ -n "$disk_gb" && "$disk_gb" -ge 30 ]] || warn "Disk: ${disk_gb:-?} GB free — need >= 30 GB (image ~15 GB)"
[[ -n "$ram_gb"  && "$ram_gb"  -ge 8  ]] || warn "RAM: ${ram_gb:-?} GB available — need >= 8 GB"

# --- Step 3: GPU (native Linux only; WSL2 uses /dev/dxg via devcontainer) ---
GPU_DONE=0
if is_wsl; then
    log "WSL2 detected — skipping host driver setup (Windows driver + /dev/dxg)."
elif ! gpu_hw_present; then
    log "No NVIDIA hardware detected — CPU-only mode."
else
    if nvidia-smi -L >/dev/null 2>&1; then
        ok "NVIDIA driver operational: $(nvidia-smi -L | head -1)"
    else
        BRANCH="$(pick_branch)" \
            || die "No linux-modules-nvidia-* package for kernel ${KVER}. Check: apt list 'linux-modules-nvidia*-${KVER}'"
        if [[ "$MODE" == "check" ]]; then
            warn "Driver not operational — would install (sudo): linux-modules-nvidia-${BRANCH}-${KVER} + linux-headers-${KVER}-generic + nvidia-driver-${BRANCH}"
        else
            log "Installing driver as matched pair (branch ${BRANCH}): prebuilt signed module + headers + userspace."
            sudo apt-get install -y \
                "linux-modules-nvidia-${BRANCH}-${KVER}" \
                "linux-headers-${KVER}-generic" \
                "nvidia-driver-${BRANCH}" \
                || die "apt install failed — see README 'GPU setup' Rules 1-2."
            driver_pair_ok "$BRANCH" \
                || die "Version skew after install (module $(modinfo -F version "/lib/modules/${KVER}/kernel/nvidia-${BRANCH}/nvidia.ko" 2>/dev/null) vs userspace $(dpkg-query -W -f='${Version}' "nvidia-driver-${BRANCH}")). See README Rule 1."

            # Live swap if nouveau is idle (refcount 0); otherwise reboot.
            nouveau_ref="$(grep '^nouveau ' /proc/modules 2>/dev/null | awk '{print $3}' || echo '')"
            if [[ -n "$nouveau_ref" && "$nouveau_ref" != "0" ]]; then
                warn "nouveau in use (refcount ${nouveau_ref}) — REBOOT REQUIRED, then re-run this script."
            else
                [[ -n "$nouveau_ref" ]] && sudo rmmod nouveau 2>/dev/null \
                    || warn "rmmod nouveau failed — a reboot may be required."
                sudo modprobe nvidia \
                    || die "modprobe nvidia failed. 'Key was rejected by service' = SecureBoot MOK not enrolled (README Rule 3)."
                nvidia-smi -L >/dev/null 2>&1 \
                    && ok "Driver live: $(nvidia-smi -L | head -1)" \
                    || warn "Driver loaded but nvidia-smi not ready — reboot if it persists."
            fi
        fi
    fi

    # Container toolkit + CDI spec (scrubbed for podman 4.9).
    if command -v nvidia-ctk >/dev/null 2>&1; then
        ok "nvidia-container-toolkit present."
    elif [[ "$MODE" == "check" ]]; then
        warn "nvidia-container-toolkit missing — would install (sudo apt install nvidia-container-toolkit)."
    else
        sudo apt-get install -y nvidia-container-toolkit
    fi

    if [[ -z "$(cdi_spec)" ]]; then
        if [[ "$MODE" == "check" ]]; then
            warn "No CDI spec — would run: sudo nvidia-ctk cdi generate --output=/etc/cdi/nvidia.yaml"
        else
            sudo nvidia-ctk cdi generate --output=/etc/cdi/nvidia.yaml \
                || die "CDI generation failed."
        fi
    fi

    if cdi_scrubbed; then
        ok "CDI spec scrubbed for podman 4.9 (0.6.0)."
    elif [[ "$MODE" == "check" ]]; then
        warn "CDI spec needs 0.6.0 scrub (podman 4.9 rejects 0.7.0 fields)."
    else
        scrub_cdi /etc/cdi/nvidia.yaml /var/run/cdi/nvidia.yaml
    fi
    GPU_DONE=1
fi

# --- Step 4: image pull (delegates to dev-up.sh: gates + retries + smoke) ---
if [[ "$MODE" == "full" ]]; then
    log "Pulling dev image (delegating to scripts/dev-up.sh)..."
    DEV_UP_YES=1 "$SCRIPT_DIR/dev-up.sh"
else
    log "--check: skipping image pull (run 'make dev-up')."
fi

# --- Step 5: GPU smoke inside a throwaway container -------------------------
if [[ "$MODE" == "full" && "$GPU_DONE" == "1" ]]; then
    if gid="$(cdi_first_gpu_id)"; then
        log "GPU smoke test (container, device ${gid})..."
        podman run --rm --device "nvidia.com/gpu=${gid}" --entrypoint python3 "$IMAGE" -c \
            "import torch, jax; assert torch.cuda.is_available(); assert any(d.platform != 'cpu' for d in jax.devices()); print('GPU OK:', torch.cuda.get_device_name(0))" \
            && ok "GPU verified inside container." \
            || warn "GPU smoke failed — re-run after reboot, or see README troubleshooting."
    fi
fi

# --- Next steps -------------------------------------------------------------
cat <<EOF

Bootstrap complete. Next:
  1. (Only if told "REBOOT REQUIRED" above) reboot, then re-run this script.
  2. make dev-run          # start the dev container (GPU if available)
  3. make dev-exec         # shell in; then: ./scripts/bootstrap-workspace.sh
  4. VS Code "Reopen in Container" works on WSL2; on native Linux see README.
EOF
ok "Done."
