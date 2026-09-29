# Plan: Thorough End-to-End Validation Drill

## TL;DR

> **Quick Summary**: A 10-phase (P0-P9) end-to-end drill validating the entire system: per-stage CI image pipeline, cache granularity proof, devcontainer publish + local consumption (GPU/omo/persistence), full deploy release drill with disposable tag, and regression checks — with evidence captured at every gate.
>
> **Deliverables**:
> - All CI paths exercised: auto-trigger push pipeline, cache-granularity re-run, release drill
> - Local consumption proven: pull-path devcontainer, 14/14 env tests (CUDA), persistent dual access, real omo task
> - Cleanup: disposable tag + release deleted, artifacts inventoried
> - Evidence: `.sisyphus/evidence/e2e-p{N}-*.txt` + final report
>
> **Estimated Effort**: XL (CI ~2.5-4h wall-clock, mostly waiting; local ~1h hands-on)
> **Parallel Execution**: NO — strictly sequential, each phase gates the next
> **Critical Path**: P0 push → P1 CI pipeline → P2 cache proof → P4 local consumption → P5 persistence → P6 omo → P7 release drill → P8 regression → P9 report

---

## Context

### Original Request
User: "Plan a thorough end to end test." Confirmed full depth on both decision points: **real GitHub Release drill** (disposable tag, deleted after) and **real omo agent task** (interactive auth, tokens spent).

### System Under Test
Everything built in the `omo-persistent-devcontainer` plan (all UNCOMMITTED in working tree): 4-stage `Containerfile.base` (toolchain/py3.13/GCC16.2, python-stack/torch-cu130, conan-deps, agents/bun+omo), `scripts/base-stage-hash.sh` per-stage hashing, `base-image.yml` (reusable, pull-gate per stage), `devcontainer.yml` → `build-devcontainer.sh` (pull-or-fail + commit/publish), `ci.yml` (conan_tag deploy, cleanroom, release on tags), persistent devcontainer (`shutdownAction: none`, GPU runArgs), `tests/test_environment.py` (14 tests), CI-only heavy-build guardrails.

### Metis Review — Critical Findings (all incorporated)
1. **P0 push auto-triggers devcontainer.yml** (paths match) → the push IS the pipeline test; P1/P3 are verification checkpoints of that run, NOT separate dispatches (avoids duplicate-build race)
2. **`gh auth token` lacks `read:packages`** by default → local private-ghcr pulls (P4) need a classic PAT — P0 user-action gate
3. **devcontainer.json has BOTH `image` and `build`** → VS Code precedence ambiguity: may BUILD (thin Dockerfile FROM base:latest) instead of PULLING the published dev image — silently different env (no baked conan cache). P4 gate detects which path won
4. **Tag push + ci.yml `paths:` filter** — may silently not trigger the release workflow → P7 step 0 probes with a warm-base throwaway tag
5. **Exec bit on `scripts/base-stage-hash.sh`** (new untracked file) must survive `git add` → P0 verifies mode 100755
6. **`build-devcontainer.sh` PUSH defaults to 1 locally** → any local run of it during the drill MUST use `PUSH=0` (except: never run it locally at all — CI-only policy)
7. **Base job 120-min timeout is tight** (~90-115 min cold estimate) → design is resumable (stage tags persist); expect possible 2 runs — not a failure
8. **`tests/test_environment.py` asserts "2060"** in device name (machine-specific; skips on CI) and requires `sm_75` in arch list → P4 checks arch list FIRST as a cheap gate
9. **`:latest` overwrites on 3 packages** (base/dev/deploy) → record digests beforehand (P0); teammates may consume them
10. **Guard tests** must use the nonexistent-registry override trick (`BASE_IMAGE=ghcr.io/arekglinka/e2e-nonexistent`) — side-effect-free
11. **P2 mutation must avoid the blank-line-before-FROM gotcha** — insert the comment line immediately AFTER `FROM conan-deps AS agents`
12. Runner disk (~20GB churn on devcontainer job) → add `df -h` logging steps expectation in evidence

---

## Work Objectives

### Core Objective
Prove the whole system works end-to-end as designed — CI builds and caches granularly, teammates consume published images, the devcontainer persists and runs omo agents, deploys release cleanly — with every claim backed by captured evidence.

### Definition of Done
- [ ] All 10 phases PASS (or explicitly documented-fail with root cause)
- [ ] Disposable release/tag deleted; leftovers inventoried
- [ ] Evidence files for every phase in `.sisyphus/evidence/`
- [ ] Final report written

### Must Have
- Every phase's acceptance criteria verified by exact commands with captured output
- CI run URLs recorded in evidence
- Image digests recorded before/after `:latest` overwrites

### Must NOT Have (Guardrails)
- NO local heavy builds (no `ALLOW_LOCAL_*` flags anywhere; guards tested only via nonexistent-registry trick)
- NO `podman system prune` / global cleanup (other projects' images on this machine — session policy)
- NO workflow/Containerfile/script edits during the drill, EXCEPT: the single sanctioned P2 mutation commit (+ its revert), and a pre-authorized one-line ci.yml trigger fix ONLY IF the P7 probe proves tags+paths don't fire
- NO omo repo mutations — the P6 task writes to `/tmp` only, ONE task, ONE agent, no chains
- NO `git checkout -- <file>` mutations without a cp backup first (uncommitted-tree rule; after P0 commit, tree is committed — but keep the cp-backup habit)
- Windows/WSL must not be rebooted mid-drill except the deliberate P5 stop/start sub-test

---

## Verification Strategy (MANDATORY)

> **ZERO HUMAN INTERVENTION for automated gates.** Two user-touch points are BY DESIGN (P0 PAT creation, P6 omo auth) — everything else is agent-executed with commands below.

### Test Decision
- **Infrastructure exists**: YES (`tests/test_environment.py`, 14 tests)
- **Automated tests**: Tests-after (the drill IS the test)
- **Framework**: pytest inside the devcontainer (P4); everything else = command + assert + evidence capture

### QA Policy
- Every phase: exact commands, exact expected values, evidence to `.sisyphus/evidence/e2e-p{N}-*.txt`
- CI observation phases: `gh run watch` + log grep + `gh api`/`skopeo inspect` (or `podman manifest inspect`) for published artifacts
- Local phases: real container runs with `--entrypoint` overrides (Lambda RIE gotcha — session learning)

---

## Execution Strategy

### Phase Sequence (strictly linear)

```
P0 Pre-flight ──► P1 CI Pipeline ──► P2 Cache Proof ──► P4 Local Consume ──► P5 Persistence ──► P6 omo Task ──► P7 Release Drill ──► P8 Regression ──► P9 Report
                      │                                       │
                      └── (P3 = dev-image verification,      └── (P4 gates: image-vs-build
                           folded into P1 as checkpoint B)        precedence + sm_75 arch)
```

(P3 exists as a verification checkpoint inside P1's run, not a separate phase.)

### Agent Dispatch Summary
- **P0, P2, P7, P8**: `unspecified-high` — multi-step, judgment, careful git/gh work
- **P1**: `quick` — watch + assert (long waits, simple asserts)
- **P4, P5**: `quick` — command + assert per gate
- **P6**: `quick` — orchestrator-assisted (user auths interactively)
- **P9**: `writing` — evidence synthesis into report

---

## TODOs

- [ ] 1. P0 — Pre-flight: commit, push, baselines, machine checks, PAT gate

  **What to do**:
  1. **Exec-bit check FIRST**: `git add -A` then `git ls-files -s scripts/base-stage-hash.sh` must show `100755`. If `100644`: `git update-index --chmod=+x scripts/base-stage-hash.sh`.
  2. **USER GATE (blocking)**: verify ghcr auth for local pulls — `gh auth status` scopes; if no `read:packages`: user creates classic PAT (read:packages; add `delete:packages` if they want ghcr version cleanup in P7) and runs `podman login ghcr.io -u arekglinka --password-stdin`. Test: `gh api /user/packages?package_type=container` (or pull any existing package). If packages `lambda_cpp26-base`/`-dev`/`lambda_cpp26` already exist from old pushes but are NOT linked to the repo, GITHUB_TOKEN pushes in CI will 403 — check linkage, delete-and-recreate if disposable (ask user if ambiguous).
  3. **Baselines file** (`.sisyphus/evidence/e2e-p0-baselines.txt`): all 4 stage hashes via `scripts/base-stage-hash.sh`; digests of any existing `:latest` on the 3 packages (`podman manifest inspect` or `skopeo inspect docker://... | jq -r .Digest`, rc-tolerant if absent); `podman ps -a --filter name=vsc-lambda_cpp26` inventory; `df -h /home /` snapshot; `podman system df`.
  4. **Machine gates**: rootless-podman storage free ≥ 30GB (abort if less, report to user); note any running `vsc-lambda_cpp26-*` containers (they'll be superseded in P4 — if any is precious, flag before proceeding).
  5. **Commit + push to main**: single commit `feat: per-stage CI caching, omo agents stage, persistent devcontainer`. Confirm push succeeded and note: **this auto-triggers `devcontainer.yml`** (paths match) — that run IS P1; do NOT also dispatch `base-image.yml` manually (duplicate-build race). Wait ~60s, capture `gh run list --workflow=devcontainer.yml --limit 1` URL into evidence.

  **Acceptance Criteria**:
  - [ ] `git status --porcelain` clean after push; exec bit 100755 recorded in evidence
  - [ ] ghcr pull-auth proven (or user-acknowledged blocker documented)
  - [ ] Baselines file exists with 4 hashes + digests + machine snapshot
  - [ ] devcontainer.yml run started (URL captured)
  - Evidence: `.sisyphus/evidence/e2e-p0-{baselines,commit,ghcr-auth}.txt`

  **Recommended Agent Profile**: `unspecified-high` — judgment on the ghcr-linkage question, careful git work. Skills: [].

  **Parallelization**: Blocks P1. Blocked by: none.

- [ ] 2. P1 — CI pipeline run: 4 stage builds + dev image publish (checkpoint A) + dev image verification (checkpoint B)

  **What to do**:
  1. `gh run watch <url-from-P0>` until conclusion (expected 60-115 min cold; **timeout at 120 min is possible and NOT a failure** — stage tags persist, re-run via `gh run rerun <id> --failed` and resume; document if it happens).
  2. **Checkpoint A (base stages)**: from the run's log, capture each ensure-step's outcome (built vs cached). Then verify from local (ghcr login from P0): `podman manifest inspect ghcr.io/arekglinka/lambda_cpp26-base:<H>-toolchain` (and `-python`, `-conan`, plain `<H_AG>`, `:latest`) — 5 manifests, all rc=0.
  3. **Checkpoint B (dev image)**: `podman manifest inspect ghcr.io/arekglinka/lambda_cpp26-dev:{<shortsha>,latest,dev-<date>}` — 3 manifests rc=0; record all digests into evidence; assert the 3 dev tags point at the same digest.
  4. Capture: run URL, conclusion, per-step durations (from `gh run view --json jobs`), `df` notes if visible in logs.

  **Acceptance Criteria**:
  - [ ] Run conclusion: success (possibly after 1 rerun)
  - [ ] All 8 manifests inspectable (5 base tags + 3 dev tags)
  - [ ] Evidence: `.sisyphus/evidence/e2e-p1-{pipeline,manifests}.txt`

  **Recommended Agent Profile**: `quick` — watch + assert. Skills: [].

  **Parallelization**: Blocks P2/P4. Blocked by: P0.

- [ ] 3. P2 — Cache-granularity proof: agents-only mutation → CI shows 3 pulls + 1 build

  **What to do**:
  1. Local hash check: current 4 hashes vs P0 baselines (must match; if not, STOP — tree drifted, re-baseline decision needed).
  2. **Sanctioned mutation**: insert a comment line `# e2e-cache-granularity-probe <UTC timestamp>` immediately AFTER the `FROM conan-deps AS agents` line (NOT before it — blank-line attribution gotcha). Verify: 3 parent hashes unchanged, agents hash CHANGED. Record both.
  3. Commit `test(e2e): cache-granularity probe`, push → devcontainer.yml auto-triggers again. `gh run watch` (expect ~15-30 min: base job pulls the 3 cached parent stages, builds ONLY the agents stage from their cached layers; dev job re-does thin build + prep with warm conan cache + commit + push).
  4. **The assertion (from CI logs of this second run)**: ensure-steps for toolchain/python/conan print "cached" (pull succeeded); agents step BUILDS. Capture the log lines.
  5. Verify new agents tag + new dev tags published (manifests rc=0).
  6. **Revert**: commit `revert: cache-granularity probe` reverting the comment (agents hash returns to P1's value — future runs pull it, no rebuild). Push (third trigger is cheap: everything cached; let it run).
  7. Local tree restored: `git status --porcelain` clean; hashes match P0 baselines again.

  **Acceptance Criteria**:
  - [ ] Second run logs show 3× "cached" + 1× build (agents)
  - [ ] New agents/dev tags published; revert pushed; local hashes == P0 baselines
  - [ ] Evidence: `.sisyphus/evidence/e2e-p2-{mutation,ci-logs,restore}.txt`

  **Recommended Agent Profile**: `unspecified-high` — the mutation is surgical (blank-line gotcha), git revert must be clean. Skills: [].

  **Parallelization**: Blocks P4. Blocked by: P1.

- [ ] 4. P4 — Local consumption: pull-path devcontainer, image-vs-build gate, 14/14 env tests, CUDA

  **What to do**:
  1. **Pre-gate (arch check, cheap)**: `podman run --rm --entrypoint python3 ghcr.io/arekglinka/lambda_cpp26-dev:latest -c "import torch; print(torch.__version__, torch.cuda.get_arch_list())"` (with GPU runArgs: `--device /dev/dxg -v /usr/lib/wsl:/usr/lib/wsl:ro -e LD_LIBRARY_PATH=/usr/lib/wsl/lib`). Assert `sm_75` in arch list. If missing: STOP, report (cu130 wheel dropped Turing — blocking finding).
  2. **VS Code Reopen in Container** (user-driven action, ~2 min): user opens the repo in VS Code (Remote-WSL) → "Dev Containers: Reopen in Container". This is one of the two by-design user touch points.
  3. **Image-vs-build precedence gate** (the Metis trap): after the container is up, `podman ps --filter name=vsc-lambda_cpp26 --format '{{.Names}} {{.Image}}'`. PASS-pull-path: Image contains `lambda_cpp26-dev`. If it shows a locally-built image (localhost/vsc-...): the `build` block won — record as FINDING (environment identical toolchain-wise but lacks baked conan cache; the "teammates pull" design promise is broken → decision point for a post-drill fix, do NOT edit devcontainer.json mid-drill). Continue the drill either way, but mark the finding prominently.
  4. **Baked-cache check**: `podman exec <ctr> bash -lc 'ls /root/.conan2/p 2>/dev/null | wc -l'` — non-zero expected on pull-path (proves prep-commit baking).
  5. **Environment suite**: `podman exec -w /workspaces/lambda_cpp26 <ctr> python3 -m pytest tests/test_environment.py -v` (needs GPU runArgs already on container — they are, from devcontainer.json). Assert **14 passed, 0 skipped, 0 failed** (the "2060" assert is machine-specific — this is the user's RTX 2060 machine, so it must pass, not skip).
  6. GPU smoke beyond the suite: `podman exec <ctr> python3 -c "import torch; a=torch.randn(1024,1024,device='cuda'); print('gpu-ok', float((a@a).sum())!=0)"`.

  **Acceptance Criteria**:
  - [ ] sm_75 arch gate passed
  - [ ] Container running; Image-name finding recorded (pull-path PASS or documented build-path finding)
  - [ ] 14 passed / 0 skipped / 0 failed inside the devcontainer
  - [ ] Evidence: `.sisyphus/evidence/e2e-p4-{arch-gate,image-path,env-suite}.txt`

  **Recommended Agent Profile**: `quick` — command + assert; user interaction is 2 minutes of Reopen-in-Container. Skills: [].

  **Parallelization**: Blocks P5. Blocked by: P2 (keeps CI quiet during local work).

- [ ] 5. P5 — Persistence + dual access: disconnect survival, stop/start, GPU after restart

  **What to do**:
  1. **Disconnect survival**: user closes the VS Code window (touch point #3, 10 seconds). After ~60s: `podman ps --filter name=vsc-lambda_cpp26` — container must still be RUNNING (this is `shutdownAction: none` working). Evidence timestamped.
  2. **Dual access while disconnected**: `make dev-exec` works — but for evidence capture use non-interactive: `podman exec <ctr> bash -lc 'echo dual-access-ok'`. Also `podman exec <ctr> bash -lc '/root/.bun/bin/omo --version'` → `omo 5.0.1 ...` (binary reachable on PATH via image ENV).
  3. **Reattach**: user reopens VS Code on the folder → "Reopen in Container" → must ATTACH to the existing container (not recreate). Evidence: same container ID before/after (`podman ps -q --filter name=vsc-lambda_cpp26` unchanged).
  4. **Stop/start cycle**: `podman stop <ctr>` → `podman start <ctr>` → `podman exec <ctr> python3 -c "import torch; print(torch.cuda.is_available())"` → must print True (GPU runArgs survive restart — stored in container config).
  5. Marker continuity check: write `/tmp/e2e-persist-marker` via exec before stop; after start, `podman exec <ctr> cat /tmp/e2e-persist-marker` → same content (layer persistence).

  **Acceptance Criteria**:
  - [ ] Container survives VS Code close (timestamped evidence)
  - [ ] Exec + omo --version work while disconnected
  - [ ] Reattach reuses same container ID
  - [ ] stop/start preserves GPU + filesystem marker
  - [ ] Evidence: `.sisyphus/evidence/e2e-p5-{persistence,dual-access,restart}.txt`

  **Recommended Agent Profile**: `quick`. Skills: [].

  **Parallelization**: Blocks P6. Blocked by: P4.

- [ ] 6. P6 — omo real agent task (user touch point: interactive auth)

  **What to do**:
  1. **USER GATE**: user runs `make dev-exec` and completes omo's interactive sign-in inside the container (touch point #4). Note: auth lives in the container layer — a later `Rebuild Container` loses it (document; not a failure).
  2. Verify auth took: `podman exec <ctr> bash -lc 'omo auth status || omo whoami || echo CHECK-MANUALLY'` (exact subcommand per omo 5.0.1 CLI; if none exists, user confirms visually).
  3. **Real task** (bounded): run ONE small omo task in the container that writes an artifact, e.g. via `podman exec -w /tmp <ctr> omo run "Write a file /tmp/e2e-omo-result.md containing a 3-line haiku about containerized agents. Do nothing else."` (adapt to omo 5.0.1's actual invocation — check `omo --help` first; the binding constraint is: ONE task, ONE agent, artifact in /tmp, no repo mutations).
  4. Assert artifact: `podman exec <ctr> cat /tmp/e2e-omo-result.md` — non-empty, plausibly a haiku.
  5. Record token-spend note (from omo's output if reported).

  **Acceptance Criteria**:
  - [ ] Auth completed in-container
  - [ ] Real task completed; artifact exists and non-empty
  - [ ] Evidence: `.sisyphus/evidence/e2e-p6-{auth,task}.txt` (transcript of task output + artifact)

  **Recommended Agent Profile**: `quick`. Skills: [].

  **Parallelization**: Blocks P7. Blocked by: P5 (auth survives the P5 stop/start, but do P6 after container lifecycle settles).

- [ ] 7. P7 — Full release drill: release branch, trigger probe, disposable tag, real GH Release, cleanup

  **What to do**:
  1. **Trigger probe** (the paths+tags ambiguity — AFTER base is warm, so a false fire costs only ~10-20 min): push disposable tag `v0.0.0-e2e.0` pointing at current main. `gh run list --workflow=ci.yml --limit 3` after ~60s. If a run started: proceed to step 3 and plan cleanup of e2e.0 too. If NOT: apply the **pre-authorized one-line ci.yml fix** (split tag triggers out of the `paths:`-filtered block), commit, push, re-probe with `v0.0.0-e2e.0b`; delete the dead tag.
  2. Push `release` branch from main (`git push origin main:refs/heads/release`) — triggers ci.yml on the branch: VERSION=0.0.0-dev.<sha>, pushes `lambda_cpp26:0.0.0-dev-<sha>` + `:latest` (deploy package — digest recorded in P0 if it pre-existed). Watch to success (~10-20 min, warm base via conan_tag).
  3. Push the real drill tag `v0.0.0-e2e.1` on the release branch HEAD → ci.yml runs the full release path: cleanroom test stage (import + tests + ldd), .so extraction, size budget, `lambda_cpp26:0.0.0-e2e.1` + `:latest` push, **real GitHub Release with sum_columns.so asset**.
  4. Verify: `gh release view v0.0.0-e2e.1 --json tagName,assets` — asset `sum_columns.so`, size ≤ 83886080; `podman manifest inspect ghcr.io/arekglinka/lambda_cpp26:0.0.0-e2e.1` rc=0; run conclusion success.
  5. **Cleanup**: `gh release delete v0.0.0-e2e.1 --yes --cleanup-tag` (and e2e.0/e2e.0b if they fired) → verify `git ls-remote --tags origin` shows none of them; delete ghcr image versions `0.0.0-e2e.1` and `0.0.0-dev-<sha>` if delete:packages scope available (else record as intentional leftovers). **Keep the `release` branch** (the system expects it to exist) unless user says otherwise.
  6. Restore any pre-existing deploy `:latest` ONLY if user flags it (digest recorded in P0).

  **Acceptance Criteria**:
  - [ ] Real Release existed with correct asset + size, deploy image tagged — then fully deleted
  - [ ] No `v0.0.0-e2e.*` tags remain on origin
  - [ ] Evidence: `.sisyphus/evidence/e2e-p7-{probe,release,verify,cleanup}.txt`

  **Recommended Agent Profile**: `unspecified-high` — trigger-probe judgment, gh release/ghcr surgery, pre-authorized-fix decision. Skills: [].

  **Parallelization**: Blocks P8. Blocked by: P6 (keep CI quiet during local phases).

- [ ] 8. P8 — Regression: guards fail-closed, hash isolation live, tree integrity

  **What to do**:
  1. **Guard: Makefile** (side-effect-free trick): `make base BASE_IMAGE=ghcr.io/arekglinka/e2e-nonexistent 2>&1` → must exit 1 with "Heavy base builds run in CI only" and list 4 missing stages; NO build attempted.
  2. **Guard: build-devcontainer.sh**: `BASE_IMAGE=ghcr.io/arekglinka/e2e-nonexistent ./scripts/build-devcontainer.sh` → must `die` with the CI-only message before any build/push (use `PUSH=0` for belt-and-braces). Exit 1.
  3. **Hash isolation live**: cp-backup `Containerfile.base`; append `# e2e-p8-probe` after the agents FROM line; assert 3 parents == P0 baselines + agents changed; restore from cp backup; assert all 4 == P0 baselines; `git status --porcelain` clean.
  4. **Tree integrity**: `git log --oneline -5` shows the drill's commits (P0 feature commit, P2 probe + revert, optional ci.yml fix); working tree clean.

  **Acceptance Criteria**:
  - [ ] Both guards fail-closed with the CI message (exit 1, no build)
  - [ ] Hash isolation verified live against P0 baselines
  - [ ] Evidence: `.sisyphus/evidence/e2e-p8-{guards,hash-isolation}.txt`

  **Recommended Agent Profile**: `unspecified-high`. Skills: [].

  **Parallelization**: Blocks P9. Blocked by: P7.

- [ ] 9. P9 — Final report: evidence synthesis + leftovers inventory

  **What to do**:
  1. Write `.sisyphus/evidence/e2e-report.md`: per-phase PASS/FAIL table with evidence-file links, CI run URLs, image digests (published + any overwritten `:latest` before/after), timings (esp. cold P1 vs cached P2 — the cache-granularity payoff in minutes), findings list (e.g. image-vs-build precedence, bun `latest` unpinned drift note, 120-min timeout behavior), token-spend note from P6.
  2. **Leftovers inventory**: ghcr tags created by the drill and their keep/delete status (stage tags: KEEP — they're the cache; dev :TAG/:dev-DATE: KEEP; e2e versions: deleted or flagged); git branches (`release`: kept); releases (none should remain).
  3. Recommendations section: any fixes surfaced (devcontainer.json image-vs-build, ci.yml trigger fix if applied, concurrency groups for rapid pushes) — as follow-ups, NOT done in this drill.

  **Acceptance Criteria**:
  - [ ] Report exists, every phase accounted for, leftovers enumerated
  - [ ] Evidence: `.sisyphus/evidence/e2e-report.md`

  **Recommended Agent Profile**: `writing` — synthesis and clarity. Skills: [].

  **Parallelization**: Blocks Final Verification Wave. Blocked by: P8.

---

## Final Verification Wave

After P9: 4 parallel reviews (plan compliance audit, evidence completeness check, leftover-artifact sweep, scope-fidelity check) — all must approve before declaring the drill complete.

---

## Commit Strategy

- P0: ONE commit of the entire working tree (`feat: per-stage CI caching, omo agents stage, persistent devcontainer`) — this is the drill's subject, not drill output
- P2: mutation commit `test(e2e): cache-granularity probe` + revert commit `revert: cache-granularity probe`
- P7 cleanup: tag/release deletion (no commits)

---

## Success Criteria

- [ ] P1: all 4 stage tags + base:latest + dev image (3 tags) published and inspectable
- [ ] P2: re-run shows 3 stages cached + only agents rebuilt, in CI logs
- [ ] P4: pull-path proven (container image = lambda_cpp26-dev), 14/14 env tests pass, CUDA works
- [ ] P5: container survives VS Code disconnect + stop/start; GPU survives restart
- [ ] P6: omo real task completes, artifact on disk
- [ ] P7: real GH Release with .so asset ≤ 80MB, deploy image tagged, then fully cleaned up
- [ ] P8: guards fail-closed, hash isolation holds vs P0 baselines
- [ ] P9: report + leftovers inventory complete
