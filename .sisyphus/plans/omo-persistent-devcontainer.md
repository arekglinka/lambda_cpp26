# Plan: omo.dev in image + persistent dual-access devcontainer

## TL;DR

> **Quick Summary**: Add the omo agent CLI (bun-based) as a 4th granular stage in the shared base image, switch stage caching to per-stage content hashes (so omo changes never recompile GCC), make the devcontainer survive VS Code disconnects (`shutdownAction: "none"`), and add a `make dev-exec` helper for podman CLI access to run omo agents while VS Code is away.
>
> **Deliverables**:
> - `scripts/base-stage-hash.sh` — single source of truth for per-stage content hashes
> - `Containerfile.base` — new `agents` stage (unzip + bun + `bun install -g omo-ai`)
> - `.github/workflows/base-image.yml` — per-stage hash gating, outputs `base_tag` + `conan_tag`
> - `.github/workflows/ci.yml` — deploy builder uses `conan_tag` (no bun/omo bloat)
> - `scripts/build-devcontainer.sh` — per-stage hash resolution via helper
> - `Makefile` — `base` target via helper + `dev-exec` target
> - `.devcontainer/devcontainer.json` — `"shutdownAction": "none"`
>
> **Estimated Effort**: Medium
> **Parallel Execution**: NO - sequential (small, interdependent file set)
> **Critical Path**: hash helper → Containerfile.base → workflows → script/Makefile → devcontainer.json → validation

---

## Context

### Original Request
1. Add https://omo.dev/ to the image (omo = `oh-my-openagent`, install: `bun install -g omo-ai`, needs the bun runtime — AL2023 Lambda base has neither bun nor node; git already present in toolchain stage).
2. Devcontainer must NOT shut down when the VS Code client disconnects.
3. Dual access: `podman exec` into the container to launch omo agents on tasks, AND attach via VS Code to inspect results.

### Research Findings
- omo.dev install = `bun install -g omo-ai` (npm package `omo-ai`, global bin lands in `/root/.bun/bin` when run as root). Bun runtime via official zip: `https://github.com/oven-sh/bun/releases/latest/download/bun-linux-x64.zip` (needs `unzip`).
- VS Code devcontainers stop the container on last-client-disconnect by default; devcontainer.json `"shutdownAction": "none"` is the canonical override.
- VS Code names devcontainers `vsc-lambda_cpp26-<hash>` (confirmed in local `podman images`: `localhost/vsc-lambda_cpp26-7aeeeedf...` exists).
- Local validation assets already in place: `lambda_conan_cache` podman volume (warm conan deps), built stage images `ghcr.io/arekglinka/lambda_cpp26-base:03ab7e25be10e346-{toolchain,python}`.
- PROBLEM with current CI design: stage tags use a whole-file hash of `Containerfile.base`. Adding an omo stage/line would change the hash → every stage tag misses in CI → GCC recompiles (~60 min). This plan fixes that with per-stage hash chaining.

### Metis-style Gaps (pre-identified)
- **Hash duplication risk**: hash logic needed in 3 places (workflow, build script, Makefile) → solved by one helper script all three call.
- **Deploy image bloat**: final base stage would carry bun+omo; deploy builder should use the conan-stage tag instead → second workflow output `conan_tag`.
- **omo auth**: omo needs interactive sign-in on first use inside the container (credentials not baked into image). Document in `make dev-exec` flow, not an image concern.

---

## Work Objectives

### Core Objective
Persistent, dual-access devcontainer with omo agents available in-image, without sacrificing the granular CI caching achieved in the previous reorganization.

### Definition of Done
- [ ] `scripts/base-stage-hash.sh <stage>` prints correct per-stage hashes; mutating one stage's lines changes only that stage's hash and descendants
- [ ] `podman build --target agents` succeeds; `omo --version` runs inside the built image
- [ ] All 3 workflows + script + Makefile pass syntax checks (`bash -n`, YAML parse)
- [ ] devcontainer.json valid JSON with `shutdownAction: "none"`
- [ ] Detached-container simulation: `podman run -d` + `podman exec` runs `omo --version`

### Must NOT Have (Guardrails)
- No credentials/API keys baked into any image layer
- No whole-file hashing that couples omo changes to GCC rebuilds
- No changes to the deployment `Containerfile` test stage (stays clean lambda/python:3.13)
- No `--name` forcing in devcontainer runArgs (VS Code manages container names; filter by `vsc-lambda_cpp26` prefix instead)

---

## TODOs

> Implementation + validation = ONE task each. Every task has QA scenarios.

- [x] 1. Create `scripts/base-stage-hash.sh` (per-stage hash helper)

  **What to do**:
  - New executable script (`chmod +x`). Usage: `base-stage-hash.sh <toolchain|python-stack|conan-deps|agents>` → prints 16-hex-char hash.
  - Algorithm: split `Containerfile.base` into stage blocks at `^FROM ` lines (awk to mktemp dir); stage names extracted via `grep -oP '(?<=^FROM \S+ AS )\S+'`.
  - Hash chain: `h(N) = sha256( h(N-1) + stage-N-block + extra-inputs(N) )[0:16]`, `h(0) = ""`.
  - `extra-inputs`: for `conan-deps` include repo files it COPYs: `find conanfile.py profiles recipes -type f | sort | xargs -r cat` (sorted = deterministic). Other stages: none.
  - Stage blocks include any comments above/inside them (awk block boundary = FROM line; comments following a FROM belong to that stage — correct attribution).
  - Error out if requested stage not found; list available stages.

  **QA Scenarios**:
  ```
  Scenario: hash isolation — mutating one stage only changes it + descendants
    Tool: Bash
    Steps:
      1. scripts/base-stage-hash.sh toolchain > /tmp/h1a; ...all 4 stages > /tmp/h*a
      2. cp Containerfile.base /tmp/backup; append a comment line "# x" to the agents stage block (before EOF)
      3. re-run all 4; diff
    Expected: toolchain/python-stack/conan-deps hashes identical; agents hash differs
    Evidence: .sisyphus/evidence/task-1-hash-isolation.txt

  Scenario: conan inputs included
    Tool: Bash
    Steps: echo "# note" >> recipes/arrow/conandata.yml (or touch a new file under recipes/); re-hash conan-deps
    Expected: conan-deps hash changes; revert file afterwards
    Evidence: .sisyphus/evidence/task-1-conan-inputs.txt
  ```

  **Recommended Agent Profile**: Category `quick`; Skills: [] (plain bash; git-master evaluated and omitted — no git operations)

- [x] 2. Add `agents` stage to `Containerfile.base`

  **What to do** (append after conan-deps stage; final stage of the file):
  ```dockerfile
  FROM conan-deps AS agents

  # https://omo.dev — bun runtime + omo agent CLI
  RUN dnf install -y unzip && dnf clean all && \
      curl -fsSL https://github.com/oven-sh/bun/releases/latest/download/bun-linux-x64.zip -o /tmp/bun.zip && \
      unzip -q /tmp/bun.zip -d /tmp && \
      mv /tmp/bun-linux-x64/bun /usr/local/bin/bun && \
      rm -rf /tmp/bun.zip /tmp/bun-linux-x64 && \
      bun install -g omo-ai

  ENV PATH="/root/.bun/bin:${PATH}"
  ```
  (Keep the existing header comment block in sync: stage table gains `: <h>-agents  bun + omo agent CLI`.)

  **Must NOT do**: no `--name` flags, no API keys, no changes to earlier stages.

  **QA Scenarios**:
  ```
  Scenario: agents stage builds and omo runs
    Tool: Bash (podman)
    Steps:
      1. Command-level pre-check (fast, before the long conan-deps layer):
         podman run --rm --entrypoint bash <python-stage-image> -c '<the RUN body verbatim>; omo --version'
      2. Full: podman build -f Containerfile.base --target agents -t ghcr.io/arekglinka/lambda_cpp26-base:$(scripts/base-stage-hash.sh agents) .
         (toolchain+python layers cache-hit locally; conan install layer runs cold ~40 min — run detached with nohup + log)
      3. podman run --rm --entrypoint omo <built-image> --version
    Expected: bun downloads, omo-ai installs, omo --version prints a version
    Evidence: .sisyphus/evidence/task-2-omo-version.txt
  ```

  **Recommended Agent Profile**: Category `quick`; Skills: [] (docker/build ops; no skill overlap)

- [x] 3. Rewrite `.github/workflows/base-image.yml` for per-stage gating

  **What to do**:
  - Compute via helper: `H_TC=$(scripts/base-stage-hash.sh toolchain)`, `H_PY=... python-stack`, `H_CONAN=... conan-deps`, `H_AG=... agents`.
  - Four sequential ensure-steps, each: `TAG="$BASE:$Hx[-suffix]"`; `podman pull $TAG` → skip; else `podman build -f Containerfile.base --target <stage> -t $TAG . && podman push $TAG`.
    - Suffixes: `:$H_TC-toolchain`, `:$H_PY-python`, `:$H_CONAN-conan`, final `:$H_AG` (+ push `:latest` with it).
  - Sequential order matters: pulling stage N-1 primes buildah blob cache so building stage N never redoes parents.
  - `workflow_call` outputs: `base_tag: $H_AG` (full, for devcontainer) and `conan_tag: $H_CONAN` (lean, for deploy builder).
  - Keep the explanatory comment about pull-primes-cache (it is the caching invariant).
  - Job outputs block currently has a copy/paste bug: `base_tag: ${{ jobs.base.outputs.base_tag }}` — fix to `steps`-level values (e.g. set via a final `set-output` step or reference `needs`-free `steps.<id>.outputs` inside the job's outputs mapping).

  **QA Scenarios**:
  ```
  Scenario: workflow YAML valid + logic dry-run
    Tool: Bash
    Steps: python3 yaml.safe_load; print the 4 computed hashes via helper; confirm tag names match the pattern used in ensure-steps
    Expected: YAML parses; hashes stable across repeated runs (same tree)
    Evidence: .sisyphus/evidence/task-3-workflow-check.txt
  ```

  **Recommended Agent Profile**: Category `quick`; Skills: [] (YAML + bash; no domain skills)

- [x] 4. Update `.github/workflows/ci.yml` + `scripts/build-devcontainer.sh`

  **What to do**:
  - ci.yml `build-test-publish`: `--build-arg BASE_TAG=${{ needs.base.outputs.conan_tag }}` (deploy builder skips bun/omo; final Lambda test image unaffected — it FROMs lambda/python:3.13 directly).
  - build-devcontainer.sh: replace the whole-file `BASE_HASH` computation with the helper: resolve each of the 4 stage tags with pull → local-exists → build fallback (same pattern as current single-stage logic, looped); final base ref = `:$H_AG`; thin build `--build-arg BASE_TAG=$H_AG`. Keep prep container + commit + push flow unchanged. Keep the header comment; update it to mention 4 granular stages and the helper as source of truth.

  **QA Scenarios**:
  ```
  Scenario: script resolves base without rebuilding cached stages
    Tool: Bash
    Steps: with the locally built stage tags present, run PUSH=0 TAG=test scripts/build-devcontainer.sh (after tasks 2/5 land); watch output lines
    Expected: "Base pulled from registry" or "already local" for all stages; no GCC compile; thin build + prep + commit complete
    Evidence: .sisyphus/evidence/task-4-script-run.txt
  ```

  **Recommended Agent Profile**: Category `quick`; Skills: [] 

- [x] 5. Makefile + devcontainer.json

  **What to do**:
  - Makefile: replace `BASE_HASH :=` whole-file shell with `$(shell scripts/base-stage-hash.sh agents)`; rewrite `base` target to loop the 4 stages (tag per stage, skip if image exists). Remove the now-stale explicit hash input list.
  - Add:
    ```makefile
    dev-exec: ## Shell into the running devcontainer (VS Code names it vsc-lambda_cpp26-*)
    	@$(PODMAN) exec -it $$(podman ps --filter name=vsc-lambda_cpp26 --format '{{.Names}}' | head -1) bash
    ```
    (add `dev-exec` to .PHONY; first-run omo auth happens inside this shell: `omo` sign-in flow.)
  - devcontainer.json: add `"shutdownAction": "none"` at top level. This keeps the container alive after VS Code disconnects so `podman exec` (omo agents) keeps working; VS Code "Reopen in Container" reattaches for inspection.

  **QA Scenarios**:
  ```
  Scenario: persistence + dual access simulation
    Tool: Bash (podman)
    Steps:
      1. podman run -d --name vsc-lambda_cpp26-sim --entrypoint sleep <agents-image> infinity
      2. podman exec vsc-lambda_cpp26-sim omo --version
      3. podman exec -it vsc-lambda_cpp26-sim bash -c 'echo alive'
      4. podman rm -f vsc-lambda_cpp26-sim
    Expected: exec works while no "client" is attached; models the VS Code-disconnected state
    Evidence: .sisyphus/evidence/task-5-dual-access.txt
  Scenario: devcontainer.json parses
    Tool: Bash — python3 -c "import json; json.load(open('.devcontainer/devcontainer.json'))"
  ```

  **Recommended Agent Profile**: Category `quick`; Skills: []

- [x] 6. FINAL VERIFICATION (run after all tasks)

  > F1 hash isolation, F2 syntax (bash×2/yaml×3/json), F4 scope check — all PASSED (see
  > `.sisyphus/evidence/task-6-final.txt`). F3 (agents image + `omo --version` + dual-access sim)
  > DEFERRED TO CI per user directive after local builds caused memory/disk pressure: the two
  > local agents-stage attempts died with environment resets; heavy builds are now CI-only
  > (guardrails: `ALLOW_LOCAL_STAGE_BUILD` / `ALLOW_LOCAL_BASE_BUILD` gates in
  > `scripts/build-devcontainer.sh` + `Makefile base`, proven to fail-fast locally with CI hints).
  > First `base-image.yml` run builds+pushes all 4 stages; F3 then = `podman pull` + the recorded
  > dual-access commands (task-5 evidence) against `:9865497dbf5e848a`.
  > POST-PLAN HARDENING (user request): CI-only guardrails landed in both files, gate verified
  > live (`make base` fails fast listing missing stages + CI hint; python stage retagged to
  > `-python` suffix convention). Local podman bloat pruned: 319→154 images.

  - [ ] F1. Re-run task-1 hash-isolation QA (guards against accidental edits to earlier stages during implementation)
  - [ ] F2. `bash -n` both scripts; YAML-parse all 3 workflows; JSON-parse devcontainer.json
  - [ ] F3. Full agents-stage image exists locally; `omo --version` passes in it; `podman run -d` + `exec` scenario (task-5) green
  - [ ] F4. Scope check: `git diff --stat` touches exactly: scripts/base-stage-hash.sh (new), Containerfile.base, .github/workflows/{base-image,ci,devcontainer}.yml, scripts/build-devcontainer.sh, Makefile, .devcontainer/devcontainer.json — nothing else

---

## Commit Strategy

- 1: `feat(ci): per-stage content hashes for base image stages` — scripts/base-stage-hash.sh (+chmod)
- 2: `feat(base): add agents stage with bun + omo CLI` — Containerfile.base
- 3+4: `refactor(ci): granular stage gating via base-stage-hash helper` — base-image.yml, ci.yml, build-devcontainer.sh
- 5: `feat(dev): persistent devcontainer + dev-exec helper` — Makefile, devcontainer.json

## Success Criteria

- [ ] `scripts/base-stage-hash.sh` isolates stage changes (agents-edit ⇒ only agents hash changes)
- [ ] omo + bun present in final base stage; `omo --version` runs
- [ ] CI never recompiles GCC for omo-only changes (per-stage pull gates)
- [ ] Container survives VS Code disconnect (`shutdownAction: "none"`); `make dev-exec` + `podman exec` both work
- [ ] Deploy builder pulls conan-stage tag (no bun/omo); final Lambda image unchanged
