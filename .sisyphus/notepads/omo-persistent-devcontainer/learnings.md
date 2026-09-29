## Session wisdom (from prior work this session-tree)

- Local stage images exist: ghcr.io/arekglinka/lambda_cpp26-base:03ab7e25be10e346-{toolchain,python} (built from the OLD whole-file hash naming). New per-stage hashes will get fresh tag names; buildah LAYER cache still hits (instructions unchanged) so rebuilds are fast.
- lambda_conan_cache podman volume holds warm conan deps (Boost/Arrow/QuantLib built for gcc16/al2023). Mount at /root/.conan2 to skip ~40 min of dep builds during validation.
- Long podman builds get interrupted by the tool harness when run synchronously. ALWAYS run >5min builds detached: nohup <cmd> > /tmp/log 2>&1 & then poll with short sleep+tail calls.
- The lambda python:3.13 base image ENTRYPOINT is the Lambda RIE — any `podman run` of these images needs `--entrypoint python3|bash|omo` or it exits immediately.
- bun install -g as root → binaries in /root/.bun/bin (needs PATH entry).
- Evidence files go to .sisyphus/evidence/ per plan QA scenarios.

## Task 1 — scripts/base-stage-hash.sh (2026-09-27)

- **CRITICAL GOTCHA**: `Containerfile.base` (and other files) are UNCOMMITTED work on this branch.
  HEAD's Containerfile.base is an OLD single-stage `python:3.12` version. NEVER use
  `git checkout -- <file>` to revert QA mutations here — it restores the stale HEAD and
  destroys uncommitted content. ALWAYS use `cp <file> /tmp/backup` + restore. (Bit me once;
  recovered byte-exact from the session's earlier Read capture, verified via chained hashes.)
- `grep -oP '(?<=^FROM \S+ AS )\S+'` FAILS on grep 3.11 / this PCRE ("lookbehind assertion
  is not fixed length"). Working equivalent: `grep -oP '^FROM \S+ AS \K\S+'` (\K idiom).
- Hash chain verified: mutating last-stage block changes only that stage (3-stage file:
  conan-deps; simulated 4-stage: agents only, toolchain/python-stack/conan-deps frozen).
- Pre-FROM header comments land in awk `stage0.part` and are excluded from every hash —
  intended per plan (file metadata, not stage content).
- Baseline hashes of current tree: toolchain=e086a1a8e997f6b2 python-stack=031006d01ca4eb49
  conan-deps=a66997bffd3aa0f5 (4th-stage sim with agents appended: conan-deps=5bce8d9dba636593,
  agents=0602f80dc884180a — will match after task 2 appends the real agents stage).
- Extra conan inputs (conanfile.py, profiles/, recipes/) confirmed hashed: touching
  recipes/arrow/conandata.yml flips conan-deps hash; recipes/ is tracked+clean.
- Evidence: .sisyphus/evidence/task-1-hash-isolation.txt, task-1-conan-inputs.txt

## Task 2 fix-up — bun/omo shebang gotcha (2026-09-27)

- omo-ai's global bin (`bun install -g omo-ai`) is a SYMLINK:
  /root/.bun/bin/omo -> ../install/global/node_modules/omo-ai/bin/omo.js,
  shebang `#!/usr/bin/env node` (no node in image). omo is bun-aware: the
  script itself calls ensureBunBinShim(), so `bun /root/.bun/bin/omo --version`
  works unmodified -> `omo 5.0.1 (engine: senpi 2026.9.27)`.
- **GOTCHA**: plain `sed -i` on a symlink REPLACES the symlink with a regular
  file. omo.js uses a relative import `./lib/bun-bin-shim.js`, which then
  resolves from /root/.bun/bin/ (wrong dir) -> "Cannot find module". Fix:
  `sed --follow-symlinks -i` (GNU sed) — edits the target, keeps the symlink.
  Plain `omo --version` then works after the shebang becomes
  `#!/usr/bin/env bun` (bun is at /usr/local/bin/bun).
- Containerfile.base agents RUN now has the for-loop sed --follow-symlinks
  rewrite after `bun install -g omo-ai`. Hashes: parents untouched
  (e086…/0310…/a669…), agents=c4326071f3d452d0.
- Hash-block attribution (confirmed earlier this task): awk splitter assigns
  any blank line BEFORE a `^FROM ` to the PRECEDING stage block — keep no
  blank line between conan-deps' last line and `FROM conan-deps AS agents`
  or the conan-deps hash flips (a669… -> 5bce…).
- Full agents build runs detached: /tmp/agents-stage-build.log, tag
  c4326071f3d452d0; parent stages cache-hit instantly, conan layer cold ~40 min.
- bash for-loop with && chains fails when last iteration doesn't match — use
  continue-pattern in Dockerfile RUN loops: `[ -f "$f" ] || continue; grep -q ... || continue; <real work>`.
  The loop exit status = last body evaluation; a trailing non-matching file made
  the whole RUN rc=1. (task 2 round 3, agents hash 9865497dbf5e848a)

## Task 3 (base-image.yml rewrite) — 2026-09-27
- GH expressions can't do arithmetic/concat inside `${{ }}`: `${{ steps.hash.outputs.base_tag-toolchain }}` is invalid (parsed as a property name). Suffixes like `-toolchain` must be literal YAML text OUTSIDE the expression; per-stage hashes therefore need their own output names (H_TC/H_PY/H_CONAN) alongside `base_tag`/`conan_tag`.
- Fixed the pre-existing self-reference bug: job outputs were `base_tag: ${{ jobs.base.outputs.base_tag }}` (circular). Correct wiring: job outputs ← `steps.hash.outputs.*`; workflow_call outputs ← `jobs.base.outputs.*`.
- Current tree hashes: toolchain=e086a1a8e997f6b2, python=031006d01ca4eb49, conan=a66997bffd3aa0f5, agents=9865497dbf5e848a (stable across runs).

## Task 4 (ci.yml + build-devcontainer.sh wiring) — 2026-09-27
- Per-stage resolution pattern: a `resolve_stage <target> <suffix> <hash> [extra-tags...]` helper keeps the pull → image-exists → build fallback DRY across 4 stages; extra tags (like `:latest`) applied only on the local-build branch, passed as trailing variadic args.
- Empty-array expansion under `set -u`: use `${tag_args[@]+"${tag_args[@]}"}` — plain `"${tag_args[@]}"` errors on bash < 4.4 when unset/empty.
- Removing a variable (e.g. `BASE_REF`) — grep the whole script for stale references afterward; `bash -n` does NOT catch unset-var usage (that's a runtime `set -u` failure).
- Helper `scripts/base-stage-hash.sh` is cwd-independent (self-cd's to repo root), so `$(scripts/base-stage-hash.sh ...)` works from anywhere; prints only the 16-hex hash on stdout.
- Current stage hashes (2026-09-27 tree): toolchain=e086a1a8e997f6b2, python=031006d01ca4eb49, conan=a66997bffd3aa0f5, agents=9865497dbf5e848a.
- ci.yml deploy builder now consumes `needs.base.outputs.conan_tag` (lean conan stage) — `base` job is a reusable-workflow call, outputs come from base-image.yml workflow_call outputs (task 3).

## Task 5 (2026-09-27)
- Makefile `base` loop pattern: encode `stage:tag` pairs in one string (`stages="toolchain:$(H_TC)-toolchain ..."`), split with `${pair%%:*}`/`${pair#*:}` — avoids a 4-branch case block and keeps H_* vars as the single make-level hash source. `podman tag ... :latest` after the loop works for both freshly-built and already-local agents images.
- `make help` in this repo prints `##` as the description for every target: the awk uses lowercase `begin` (a regex, not BEGIN), so `FS=":.*?## "` never gets set. Pre-existing cosmetic bug, left untouched (out of task-5 scope).
- `make -n` still evaluates `$(shell scripts/base-stage-hash.sh ...)` — confirmed offline-safe, printed real hashes in dry-run.
- Agents-stage build (`9865497dbf5e848a`) was still in boost configure at task-5 time; dual-access simulation deferred to task 6 F3 (commands recorded in .sisyphus/evidence/task-5-dual-access.txt).

- policy: heavy base-stage builds (GCC/Arrow/QuantLib) are CI-only; local default is pull-or-fail; escape hatch ALLOW_LOCAL_STAGE_BUILD=1 / ALLOW_LOCAL_BASE_BUILD=1

## POLICY (user directive, 2026-09-29): heavy builds are CI-only
- Local stage builds (GCC/Arrow/QuantLib compiles) caused memory/disk pressure on the dev box.
- DEFAULT: local resolution is pull-or-fail. Guards: ALLOW_LOCAL_STAGE_BUILD=1 (build-devcontainer.sh resolve_stage) and ALLOW_LOCAL_BASE_BUILD=1 (make base) are explicit opt-ins only.
- Trigger builds via CI: push to main, or `gh workflow run base-image.yml`. The first CI run builds+pushes all 4 stage tags; afterwards everything is pull-cached.
- F3 (omo --version in final image + dual-access sim) runs after first CI publish against tag :9865497dbf5e848a — commands recorded in .sisyphus/evidence/task-5-dual-access.txt.
- Local podman hygiene: dangling-image prunes after killed builds; stale-naming duplicates removed (319→154 images). Remaining tagged images belong to user's other projects — do not prune unasked.
