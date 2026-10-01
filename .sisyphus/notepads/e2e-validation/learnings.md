# e2e-validation session learnings
## 2026-09-29 P0 lessons
- REBASE OURS/THEIRS INVERSION: during `git rebase`, `--ours` = upstream (rebase target), `--theirs` = YOUR commit being replayed. Opposite of merge semantics. A `git checkout --ours` during rebase conflict resolution silently took the remote's old versions of 3 files into the commit. ALWAYS diff HEAD vs expectation after resolving.
- GitHub auto-disables workflows after ~60 days repo inactivity (state: disabled_inactivity) — disabled workflows ignore push events silently. Fix: `gh workflow enable "<name>"`, verify via `gh workflow list`.
- ghcr packages (lambda_cpp26-dev/base) pre-exist and CI previously pushed via GITHUB_TOKEN (repo auto-linked) — CI pushes work without a PAT. The PAT (write/delete:packages) is only needed for LOCAL pulls + ghcr version cleanup.
- P4 restructured: dev-image validation runs CI-side (verify job); local pulls of the 15GB dev image OOM the WSL box — forbidden.

conftest find_extension genexp guard bug: 'for f in os.listdir(x) if os.path.isdir(x)' evaluates listdir FIRST — isdir is an item filter, not a guard. Guard before listdir.
gdb/valgrind lost in devcontainer->Containerfile.base unification; placed in agents stage dnf so only that stage's hash changes (parents stay cached)

- Python version now lives in exactly 2 ARG tokens + test floor; check-wheels.sh pre-flight prevents wasted CI on missing cp wheels.
- polars 1.44 = universal wheel + auto polars-runtime-32 dep (rt64 extra = optimized runtime, avoided for CPU compat); jax[cuda13] on its own layer separate from the torch index line.
- cupy installs as dedicated cupy-cuda13x distribution (not an extra); pandas 3.0 cp314 native.
- app layer (jupyterlab/notebook/streamlit) isolated in its own RUN for independent invalidation; VS Code auto-forwards devcontainer ports so jupyter/streamlit need no runArgs.
- viz stack (altair 6/seaborn/matplotlib) joins the app layer; floors refreshed to Oct-2026 latests (conan 2.33, jupyterlab 4.6, notebook 7.6); seaborn 0.13.2 is still latest — pandas-3 compat validated empirically by the CI verify test.
- gpu_showcase.ipynb pattern: interact callbacks invoked once with defaults so headless nbconvert produces real output; GPU guarded with CPU fallback labels.
- nbconvert --output must be a bare filename (use cwd=); containerized notebook tests need their notebook dir mounted too.
nbconvert output placement: default output-dir = SOURCE notebook's dir, not cwd — always pass --output-dir explicitly.

- dev-up.sh: one-command local launcher (auth→vscode-fix→gates→pull w/ retry→smoke); dead rootful socket in VS Code machine settings was the local-run blocker. Resource gates (disk≥30G/ram≥8G) abort before any bytes are pulled — the OOM lesson; smoke test MUST override --entrypoint (Lambda RIE base).
- dev-run.sh = VS Code-free runner mirroring devcontainer.json (GPU flags, :Z workspace, 8888/8501 ports, RIE override); dev-exec prefers script-created container (lambda_cpp26-dev) and falls back to VS Code's vsc-lambda_cpp26-*.
- WSL exports NAME=hostname → never use NAME as a script default-var (dev-run.sh named the container "DESK"; renamed to DEV_CONTAINER_NAME). Multi-CUDA-stack images need the pip-nvidia lib dir FIRST in LD_LIBRARY_PATH (torch/jax preload their bundled NVRTC, starving cupy's lazy kernel compiles → libnvrtc-builtins.so.13.0 dlopen failure); podman -e overrides the image ENV, so restate the image's entries. XLA_PYTHON_CLIENT_PREALLOCATE=false on small VRAM cards (jax grabs 75% by default).
