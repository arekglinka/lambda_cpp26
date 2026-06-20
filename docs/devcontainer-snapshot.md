# Devcontainer Snapshot Workflow

This doc covers the **local snapshot** devcontainer configuration at
`.devcontainer/local-snapshot/`: what it is, why it exists, what it
restores, and how to bootstrap a fresh checkout against it. The original
`.devcontainer/devcontainer.json` (build-from-Dockerfile) is unchanged and
remains the canonical config; the snapshot is an optional fast-start path.

---

## Why two devcontainer configs?

The Dockerfile in `.devcontainer/Dockerfile` builds GCC 16.1.0 from source.
On a fresh machine that takes **30+ minutes**. Once built, the image is
published to `ghcr.io/arekglinka/lambda_cpp26-dev:latest` so teammates can
`podman pull` it (2–5 min) instead of building.

The snapshot workflow is a third option: **export the running devcontainer
from a machine that already has it (a colleague, a CI box, another laptop
of yours) and import it locally**. This avoids the 30-min build *and* the
registry round-trip, and produces a byte-identical filesystem snapshot of
the container's state — including the conan cache, GCC install, clangd
binary, and any in-place fixes applied since the last `podman push`.

| Config | Image source | Time to first run | When to use |
|---|---|---|---|
| `.devcontainer/devcontainer.json` (default) | `ghcr.io/arekglinka/lambda_cpp26-dev:latest`, falls back to `Dockerfile` build | 2–5 min pull, or 30+ min build | Normal team workflow |
| `.devcontainer/local-snapshot/devcontainer.json` | `localhost/devcontainer-snapshot:latest` (local podman image) | Seconds (no build, no pull) | Pairing, offline, custom-toolchain experiments |

VSCode's "Reopen in Container" command shows a **picker** when both configs
exist as siblings — pick whichever suits the moment.

---

## Producing a snapshot image

The snapshot is created by streaming `podman export` from the source
machine into `podman import` on the target. The script
[`agutil/pull-devcontainer.sh`](../../agutil/pull-devcontainer.sh)
automates this:

```bash
# From the target machine (the one that wants the snapshot):
~/wsp/agutil/pull-devcontainer.sh <container-name-on-source>
```

It streams `podman export <c> | gzip | gunzip | podman import -` over SSH,
producing `localhost/devcontainer-snapshot:latest` locally. A typical
snapshot is ~10 GB (Amazon Linux 2023 + GCC 16 + clangd + Python 3.12 +
the conan dependency cache).

### What's in the snapshot

Everything in the source container's filesystem at export time:

- ✅ `/opt/gcc16/` — full GCC 16.1.0 install
- ✅ `/var/lang/` — Python 3.12, clangd 22.1.1, conan, cmake (pip-installed)
- ✅ `/root/.conan2/` — pre-built dependency cache (Arrow, QuantLib, Boost, …)
- ✅ `/tmp/conan-profiles/` — the `al2023` profile baked in by the Dockerfile
- ✅ `/tmp/recipes/` — local Conan recipes (arrow, quantlib)
- ✅ System packages from `dnf install` (gdb, valgrind, clang-tools-extra, …)

### What's NOT in the snapshot

- ❌ **Bind-mounted workspace** — `/workspaces/lambda_cpp26` is a bind-mount
  from the host, never part of the container's filesystem. Clone the repo
  separately on the target machine.
- ❌ **Named volumes** — the `vscode` named volume (VSCode server
  side-channel) is not in the snapshot; harmless, VSCode recreates it.
- ❌ **Image metadata** — `podman import` produces a **flat filesystem**.
  `CMD`, `ENTRYPOINT`, `ENV`, `WORKDIR`, `USER`, `EXPOSE` from the original
  Dockerfile are all stripped. The `containerEnv` block in
  `local-snapshot/devcontainer.json` restores the operationally-important
  ones (see below).

---

## The `containerEnv` restoration (critical)

Because `podman import` drops image metadata, the following `ENV`
directives from the Dockerfile are **absent** in the snapshot:

| Dockerfile directive | Effect when missing | Restored by |
|---|---|---|
| `ENV CC=/opt/gcc16/bin/gcc` | clangd/cmake default to system `cc` | `containerEnv.CC` |
| `ENV CXX=/opt/gcc16/bin/g++` | same | `containerEnv.CXX` |
| `ENV PATH=/opt/gcc16/bin:...` | shells find GCC 11 (system default) instead of 16 | `containerEnv.PATH` (explicit list) |
| `ENV LD_LIBRARY_PATH=/opt/gcc16/lib64` | runtime linking of `libstdc++.so` fails | `containerEnv.LD_LIBRARY_PATH` |
| `ENV CFLAGS=-std=gnu17` | benign — overwritten per-target anyway | `containerEnv.CFLAGS` |
| `ENV CXXFLAGS=` | benign | `containerEnv.CXXFLAGS` |
| `WORKDIR /workspace` | irrelevant — VSCode mounts to its own path | (not restored) |
| `USER root` | irrelevant — `remoteUser: root` in devcontainer.json sets this | (not restored) |

`containerEnv` is a runtime-only overlay — it adds these env vars to the
container at `podman run` time without modifying the image. See
[`local-snapshot/devcontainer.json`](../../.devcontainer/local-snapshot/devcontainer.json)
for the canonical values.

To verify after opening the snapshot container:

```bash
echo $PATH               # must include /opt/gcc16/bin and /var/lang/bin
which g++                # must be /opt/gcc16/bin/g++
g++ --version | head -1  # must be 16.1.0
which clangd             # must be /var/lang/bin/clangd
```

---

## Configuring VSCode Dev Containers for podman

Required once per machine — podman is not the default. The Dev Containers
extension needs two settings:

```jsonc
// ~/.config/Code/User/settings.json  (Linux)
{
    "dev.containers.dockerPath": "podman",
    "dev.containers.dockerSocketPath": "/run/user/1000/podman/podman.sock"
}
```

- `dockerPath` — VSCode calls `podman` instead of `docker`
- `dockerSocketPath` — VSCode talks to the **rootless** user socket
  directly (no sudo)

The socket path is `$XDG_RUNTIME_DIR/podman/podman.sock` — usually
`/run/user/<uid>/podman/podman.sock`. Verify it responds before opening
the container:

```bash
curl -sf --unix-socket /run/user/$(id -u)/podman/podman.sock \
    http://localhost/v5.0.0/libpod/info && echo "socket OK"
```

The legacy `remote.containers.dockerPath` setting still works but is
deprecated; use the `dev.containers.*` namespace.

### Rootless podman gotchas

- The rootful socket at `/run/podman/podman.sock` requires sudo — don't
  point VSCode at it on a single-user workstation.
- The user socket lives in `/run/user/<uid>/` which is tied to your login
  session. If you log out, the socket disappears (and VSCode can't reach
  containers until you log back in).
- `systemctl --user enable --now podman.socket` makes it auto-start at
  login. Most distros enable it on first podman use; verify with
  `systemctl --user status podman.socket`.

---

## First-time setup after `git clone`

Once you have the snapshot image locally and VSCode configured for podman:

```bash
git clone <repo> lambda_cpp26
cd lambda_cpp26
code .                                          # open in VSCode
```

In VSCode:

1. `Ctrl+Shift+P` → **Dev Containers: Reopen in Container**
2. **Picker appears** — choose `lambda-cpp26 (local snapshot)`
3. Container starts in seconds (no build, no pull)
4. Inside the container's integrated terminal, run the bootstrap:

   ```bash
   ./scripts/bootstrap-workspace.sh
   ```

   This populates `build/Release/` (clangd's `compile_commands.json` +
   the pybind11 `.so`) and smoke-tests pytest. See the script header for
   `SKIP_TESTS=1` and `FORCE_CLEAN=1` knobs.

5. `Ctrl+Shift+P` → **clangd: Restart language server**
   (only needed the very first time — clangd auto-detects
   `compile_commands.json` changes on subsequent runs)

---

## Why both clangd AND cpptools are installed

The devcontainer.json `customizations.vscode.extensions` list installs both:

- `llvm-vs-code-extensions.vscode-clangd` — primary IntelliSense, driven by
  `compile_commands.json` from Conan's CMake
- `ms-vscode.cpptools` — kept for its debugger-side utilities used by the
  C/C++ debugging workflows

Having both active causes a known conflict: even with
`C_Cpp.intelliSenseEngine: "Disabled"`, cpptools **still scans `#include`
lines** and renders red squiggles on unresolved ones — its
`C_Cpp.errorSquiggles` setting defaults to `"enabled"` and is independent
of `intelliSenseEngine`. The result: every `#include` line glows red even
though clangd (the active engine) resolves them all correctly.

The fix is in `.vscode/settings.json`:

```jsonc
{
    "C_Cpp.intelliSenseEngine": "Disabled",
    "C_Cpp.errorSquiggles": "disabled",      // ← the actual fix
    "C_Cpp.dimInactiveRegions": false        // ← also suppresses cpptools's
                                             //   #ifdef dimming that conflicts
                                             //   with clangd's view
}
```

After editing these, **reload the window** (`Ctrl+Shift+P` →
`Developer: Reload Window`) — cpptools reads these at activation only.

### Verifying which extension is producing a squiggle

Hover over any red marker. The tooltip's bottom-right names the source:
"clangd" vs "C/C++ extension". If clangd is healthy (verifiable with
`clangd --check=<file>` — see below) and you still see red includes, the
culprit is cpptools.

### Verifying clangd's view directly

To see exactly what clangd computes for a source file, run it in `--check`
mode from the container's terminal:

```bash
/var/lang/bin/clangd \
    --check=$(pwd)/src/sum_columns.cpp \
    --compile-commands-dir=$(pwd)/build/Release \
    --query-driver=/opt/gcc16/bin/g++ \
    -j=4
```

A healthy run ends with `All checks completed, N errors` where the N
"errors" are unrelated code-action tweak failures (ExtractFunction etc.),
not diagnostics. Zero header errors means clangd is fully resolved.

---

## LLDB debugging warnings (benign)

When launching under CodeLLDB inside the snapshot container, two warning
classes appear in the Debug Console:

### "Could not disable address space layout randomization (ASLR)"

LLDB tries to disable ASLR for the debuggee to give deterministic
addresses. The container's default seccomp profile blocks the
`personality(2)` syscall LLDB uses, so ASLR stays enabled. Debugging
works fine either way — the warning is just LLDB complaining.

To suppress, `.vscode/launch.json` already has:

```jsonc
"initCommands": [
    "settings set target.inherit-env true",
    "settings set target.disable-aslr false"
]
```

To actually disable ASLR (deterministic addresses per run), add to
`local-snapshot/devcontainer.json`:

```jsonc
"runArgs": [
    "--cap-add=SYS_PTRACE",
    "--security-opt", "seccomp=unconfined"
]
```

Cost: container restart. Benefit: marginal — only matters for repeated
runs that compare raw addresses. Rarely worth it.

### "No LZMA support found for reading .gnu_debugdata section"

LLDB in the snapshot wasn't compiled with `liblzma` support, so it can't
read the LZMA-compressed mini-debug-info embedded in some system `.so`
files (`/lib64/libm.so.6`, `/var/lang/lib/libreadline.so.8`, etc.). These
are auxiliary mini-debug-symbols; the real DWARF info from your own
`sum_columns.cpython-*.so` (built with `-g` per `src/CMakeLists.txt`)
loads fine. **No action needed.**

Suppressing the warning would require rebuilding LLDB with
`-DLLDB_ENABLE_LZMA=ON`, which is not worth the complexity.

---

## Reference: all configuration files involved

| File | Scope | Purpose |
|---|---|---|
| `Containerfile.gcc-base` | Image build | Shared foundation (GCC 16 + system pkgs + pip tools + conan setup). Cached by content hash on ghcr.io. |
| `Containerfile.arrow-deps` | Image build | Builds ONLY Apache Arrow + transitive deps. `FROM gcc-base`. Parallel with `quantlib-deps`. Cached by content hash. |
| `Containerfile.quantlib-deps` | Image build | Builds ONLY QuantLib + boost. `FROM gcc-base`. Parallel with `arrow-deps`. Cached by content hash. |
| `.devcontainer/Dockerfile` | Image build | Multi-stage assembled devcontainer. `FROM` all three cached intermediates, merges Conan caches via `--mount=type=bind`, adds dev tools. |
| `.devcontainer/devcontainer.json` | Image build | Default config — uses `image` from registry with `build` fallback |
| `.devcontainer/local-snapshot/devcontainer.json` | Image use | Snapshot config — uses local image, restores `containerEnv` |
| `.vscode/settings.json` | Workspace | Podman dockerPath, cpptools suppression, clangd args |
| `.vscode/launch.json` | Workspace | CodeLLDB configs (4: standalone-debug ×2, pytest-debug ×2) |
| `.vscode/tasks.json` | Workspace | Build tasks for `preLaunchTask` chains |
| `.clangd` | Workspace | clangd project config — adds `-std=c++26` |
| `~/.config/Code/User/settings.json` | User (host) | VSCode host-side: `dev.containers.dockerPath: podman` etc. |
| `scripts/bootstrap-workspace.sh` | One-shot | Populates `build/Release/` after checkout |
| `scripts/push-devcontainer.sh` | One-shot | Commits the currently running devcontainer and pushes (fast local-share path) |
| `scripts/save-devcontainer-tarball.sh` | One-shot | Exports devcontainer to gzip'd OCI tarball for airgapped distribution |
| `scripts/build-devcontainer.sh` | Deprecated | Single-job predecessor of the 4-job parallel workflow. Kept for historical reference. |
| `.github/workflows/devcontainer.yml` | CI | 4-job parallel pipeline: gcc-base → (arrow-deps ‖ quantlib-deps) → assemble |
| `agutil/pull-devcontainer.sh` | External tool | Streams `podman export` from a remote host into a local snapshot image |
| `agutil/wsl-autostart.ps1` | External tool | Windows-side: keeps WSL2 alive across session switches (only relevant if the source/target is WSL2) |
