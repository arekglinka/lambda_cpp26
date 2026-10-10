# lambda_cpp26

AWS Lambda-compatible C++26 compute: a statically-linked pybind11 extension
(Arrow + QuantLib, ≤ 80 MB `.so` budget) built with GCC 16 / Conan 2, plus a
GPU-capable ML dev container (torch/jax/cupy on CUDA 13) for experimentation.

Everything runs in one prebuilt container image — the host only needs Podman
and (optionally) an NVIDIA driver.

## What the dev image contains

| Component | Location / version |
|---|---|
| Python (torch, jax, cupy, polars, pandas, streamlit, jupyter) | `/var/lang/bin/python3` (3.14) |
| GCC | `/opt/gcc16/bin/g++` (16.x) |
| clangd | `/var/lang/bin/clangd` |
| Conan | 2.33, deps pre-baked (Arrow 18, QuantLib 1.38) |
| Conan profiles | `/tmp/conan-profiles/` (`al2023`, `default`, `dev-shared`) |

Image: `ghcr.io/arekglinka/lambda_cpp26-dev:latest` (~15 GB unpacked; rebuilt
weekly by CI — `git pull` + re-pull gets the fresh one).

## Host requirements

| Requirement | Notes |
|---|---|
| Ubuntu 24.04 (native or WSL2) | Other distros work but GPU setup below is Ubuntu-specific |
| ≥ 30 GB free disk | Image + layers; two aborted pulls have OOM'd smaller setups |
| ≥ 8 GB available RAM | Dev-up gates abort before pulling otherwise |
| Podman ≥ 4.9 | `sudo apt install podman` |
| Podman user socket | `systemctl --user enable --now podman.socket` |
| gh CLI, logged in | `gh auth login` (image pulls work without extra scopes — the package is public) |
| VS Code + "Dev Containers" ext | Optional — `make dev-run` is the VS Code-free path |

## Quick start

```bash
git clone git@github.com:arekglinka/lambda_cpp26.git
cd lambda_cpp26
./scripts/install.sh          # host prep: prereqs, GPU chain, image pull, smoke test
make dev-run                  # start the container (GPU if available)
make dev-exec                 # shell into it
```

Inside the container (first time only — populates `build/Release/`):

```bash
./scripts/bootstrap-workspace.sh          # conan install+build → compile_commands.json + .so
jupyter lab --ip=0.0.0.0 --no-browser     # optional, http://localhost:8888
```

Incremental C++ rebuild after editing `src/`:

```bash
make -C build/Release sum_columns -j"$(nproc)"     # ~5-10 s, skips conan
```

### VS Code

`Dev Containers: Reopen in Container` works out of the box on WSL2. On native
Linux, the repo's `devcontainer.json` carries WSL-only `runArgs`
(`--device=/dev/dxg`, `/usr/lib/wsl` mount) that will abort container start —
either delete those two `runArgs` entries locally, or just use
`make dev-run` / `make dev-exec`, which handle both platforms.

## GPU setup (native Linux)

The container gets the GPU via CDI. The host needs a driver whose **kernel
module version exactly equals the userspace version** — NVML/CUDA refuse any
mismatch (symptom: `Failed to initialize NVML: Driver/library version
mismatch`). `scripts/install.sh` enforces the rules below automatically; they
are documented here because every one of them was learned the hard way.

**Rule 1 — install kernel module and userspace as a matched pair.**
Ubuntu's prebuilt `linux-modules-nvidia-<BRANCH>-<KVER>` packages are
Canonical-signed (no SecureBoot dance) but their embedded version is **frozen
at build time** — the `-28` kernel carried module 595.84 while userspace had
moved to 595.99. After installing, always verify:

```bash
modinfo -F version nvidia                     # kernel module version
cat /proc/driver/nvidia/version               # what actually loaded
nvidia-smi                                    # userspace; fails on mismatch
```

**Rule 2 — the module package needs kernel headers to assemble.**
`linux-modules-nvidia-*` is a stub: its postinst links `bits/*.o` + applies
Canonical signatures, using `module.lds` and `objtool` from
`/usr/src/linux-headers-$(uname -r)-generic/`. Install
`linux-headers-$(uname -r)-generic` together with it, or the postinst dies
with `sha256sum: WARNING: 5 listed files could not be read`.
Note: on HWE kernels the common-headers dependency is named
`linux-hwe-<X>-headers-<VER>`, not `linux-headers-<VER>` — the `-generic`
package resolves it via Depends, so just install the `-generic` one.

**Rule 3 — DKMS instead of prebuilt ⇒ SecureBoot needs MOK enrollment.**
DKMS modules are signed with a machine MOK key (`/var/lib/shim-signed/mok/`).
If the key was never enrolled, `modprobe nvidia` fails with *Key was rejected
by service*. Fix = `sudo mokutil --import /var/lib/shim-signed/mok/MOK.der`,
reboot, enroll in the blue MOK Manager screen. Prefer Rule 1's prebuilt path
to skip this entirely.

**Rule 4 — container toolkit + CDI spec.**

```bash
sudo apt install -y nvidia-container-toolkit
sudo nvidia-ctk cdi generate --output=/etc/cdi/nvidia.yaml
```

Two podman ≤ 4.9 quirks (handled by `scripts/dev-run.sh`, relevant if you do
this by hand):

- Podman 4.9's CDI parser rejects specs from nvidia-ctk ≥ 1.20 (CDI 0.7.0
  field `additionalGids`) with `unresolvable CDI devices`. Scrub:

  ```bash
  sudo python3 - <<'EOF'
  import yaml
  for p in ("/etc/cdi/nvidia.yaml", "/var/run/cdi/nvidia.yaml"):
      try: spec = yaml.safe_load(open(p))
      except FileNotFoundError: continue
      spec["cdiVersion"] = "0.6.0"
      for d in spec.get("devices", []):
          d.get("containerEdits", {}).pop("additionalGids", None)
      spec.get("containerEdits", {}).pop("additionalGids", None)
      yaml.safe_dump(spec, open(p, "w"), sort_keys=False)
  EOF
  ```

- The `nvidia.com/gpu=all` qualifier is podman ≥ 5 only. Pass each device:
  `--device nvidia.com/gpu=0` (space form — `--device=name` also breaks CDI
  resolution on 4.9).

**Rule 5 — devices bake in at container creation.** Changing the driver or
CDI spec does not affect a running/stopped container; recreate it
(`podman rm -f lambda_cpp26-dev && make dev-run`).

**WSL2:** none of the above — the Windows driver exposes `/dev/dxg`, and the
`devcontainer.json` runArgs handle passthrough. `dev-run.sh` detects WSL and
skips CDI.

## Verify

```bash
# host
nvidia-smi -L                                   # lists the GPU
podman run --rm --device nvidia.com/gpu=0 --entrypoint python3 \
  ghcr.io/arekglinka/lambda_cpp26-dev:latest \
  -c "import torch, jax; print(torch.cuda.is_available()); print(jax.devices())"
# expect: True / [CudaDevice(id=0)]
```

## Daily use

| Command | What it does |
|---|---|
| `make dev-up` | Pre-flight + pull image with retries + smoke test |
| `make dev-run` / `dev-down` | Start (idempotent, GPU-aware) / stop the container |
| `make dev-exec` | Shell into the running container |
| `make dev-run` then Jupyter `:8888`, Streamlit `:8501` | Ports already published |
| `make build` / `make test` / `make ci` | Lambda-target build + cleanroom test + size budget |
| `./scripts/bootstrap-workspace.sh` | Full conan rebuild of `build/Release/` (also re-runs pytest) |

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `Failed to initialize NVML: Driver/library version mismatch` | Kernel module ≠ userspace version | See Rule 1; align via prebuilt pair or downgrade/upgrade one side |
| `Key was rejected by service` on `modprobe nvidia` | SecureBoot + unenrolled MOK (DKMS path) | Rule 3, or switch to prebuilt modules (Rule 1) |
| `sha256sum: WARNING: 5 listed files could not be read` during install of `linux-modules-nvidia-*` | Missing kernel headers (assembly needs `module.lds`/`objtool`) | `sudo apt install linux-headers-$(uname -r)-generic && sudo dpkg --configure -a` |
| `E: Unable to locate package linux-headers-<VER>` | HWE common headers are named `linux-hwe-<X>-headers-<VER>` | Install only the `-generic` package; apt pulls the right common one |
| `unresolvable CDI devices nvidia.com/gpu=...` | CDI 0.7.0 spec on podman ≤ 4.9 | Rule 4 scrub |
| `Error: stat nvidia.com/gpu='0'` | Name with literal quotes (safe_dump) or `--device=name` form | Re-scrub spec; use space-form `--device nvidia.com/gpu=0` |
| `cuInit(0) failed: Unknown CUDA error 303` inside container | No GPU devices in container (created before CDI existed) | Rule 5: recreate the container |
| `python3.12 not on PATH` in bootstrap | Image moved to Python 3.14 | Pull current image + current scripts (`git pull`) |
| Podman socket errors in VS Code | `docker.host` pointing at rootful socket | `dev-up.sh` auto-fixes to `docker.dockerPath: podman` |

## More docs

- `Contributing.md` — project conventions (pre-dates the GPU flow; this README supersedes its setup section)
- `docs/` — research notes, upgrade guides
- `.github/workflows/` — image build (`devcontainer.yml`), CI (`ci.yml`)
