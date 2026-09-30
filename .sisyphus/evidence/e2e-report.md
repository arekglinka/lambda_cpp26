# E2E Drill Report — 2026-09-29

## Phase Results

| Phase | Status | Evidence |
|---|---|---|
| P0 Pre-flight | ✅ DONE (PAT gate ⏳ user) | e2e-p0-{baselines,commit}.txt |
| P1 CI pipeline | ✅ SUCCESS (1h21m cold, no timeout) | e2e-p1-pipeline.txt |
| P2 Cache granularity | ✅ PROVEN (3 pulled + agents built; reverted) | e2e-p2-cache-proof.txt |
| P4 Local consumption | ⏸ AWAITING USER (PAT + Reopen-in-Container) | — |
| P5 Persistence/dual access | ⏸ AWAITING P4 | — |
| P6 omo real task | ⏸ AWAITING USER (auth) | — |
| P7 Release drill | ✅ FULL DRILL + CLEANUP | e2e-p7-release-drill.txt |
| P8 Regression | ✅ guards fail-closed + isolation holds | e2e-p8-guards.txt |
| P9 Report | ✅ this file | — |

## Headline numbers
- Cold pipeline (P1): **1h21m55s** · Warm deploy (post-fix dispatch): **6m05s** · Cached release drill (P7): **7m23s**
- Caching granularity: agents-only change rebuilt ONLY the agents stage; toolchain/python/conan pulled from registry (CI log-proven)
- Release: real GH Release v0.0.0-e2e.1 with `sum_columns.so` 43,856,272 bytes (41.8 MB ≤ 80 MB budget) — created, verified, deleted

## Bugs found & fixed during the drill
1. **Hash reproducibility**: helper hashed untracked junk (`__pycache__/*.pyc`) with locale-dependent `find|sort` → local≠CI. Fixed: `git ls-files | LC_ALL=C sort` — local now byte-matches CI (verified).
2. **Deploy builder tag wiring**: `ci.yml` passed bare `conan_tag` but only `:-conan` suffixed tag existed → builder FROM 404. Fixed: suffix inline in ci.yml + plain-hash alias in base-image.yml.
3. **Workflow auto-disabled**: `DevContainer Image` was `disabled_inactivity` (repo dormant ~3 months) → push fired nothing. Fixed: `gh workflow enable`.

## Process findings (documented, no action needed)
- Rebase ours/theirs inversion silently reverted 3 files during conflict resolution — recovered from cb66bcf, lesson recorded in notepad.
- Rebase merged the user's June-21 parallel line: their image-only devcontainer.json shape ADOPTED (kills the image-vs-build precedence trap); their conan recipe fixes flowed in (hashes legitimately shifted).
- bun installs unpinned `latest`: omo-ai went 5.0.1 → 5.1.1 between builds. Recommendation: pin `omo-ai@<version>` ARG when stability matters.
- RUN-layer cache on fresh CI runners: pulled parent tags do NOT provide buildah RUN-cache for deeper stages (P2 base job ~75 min rebuilding conan despite pulled tag). Recommendation: buildah `--cache-from` support or accept (correctness unaffected).
- `release` branch push did not fire ci.yml (tags drive releases — non-blocking).

## Leftovers inventory
- **ghcr versions awaiting `delete:packages` (user PAT)**: `lambda_cpp26:0.0.0-e2e.1`, `lambda_cpp26:0.0.0-dev-05b0dd1`
- **git**: `release` branch KEPT (system design); no e2e tags remain on origin ✓
- **Local machine**: zero heavy builds run locally ✓ (CI-only policy held all drill)

## Pending user gates (to finish P4→P6)
1. Classic PAT (write:packages + delete:packages) → `podman login ghcr.io -u arekglinka --password-stdin` → P4 local pulls + manifest re-verification + ghcr leftover cleanup
2. VS Code → "Dev Containers: Reopen in Container" → P4 image-path check + 14/14 env suite
3. Close VS Code (P5 persistence) → `make dev-exec` → omo auth → P6 real task

---
# FINAL UPDATE — 2026-09-30

## P4 RESTRUCTURED (CI-side) — DONE
Local dev-image pulls OOM the WSL box (twice). Permanent fix: `verify` job in devcontainer.yml runs the env suite against the published image in CI.
- Run 36628770065: conftest fresh-checkout crash found → fixed (os.listdir guard)
- Run 36747279085: gdb/valgrind gap found (lost in base unification) → restored in agents stage
- Run 36748733161: **ALL GREEN — 13 passed, 1 skipped (GPU) in 8.77s** inside lambda_cpp26-dev:latest

## P5/P6 — CLOSED BY CONSTRAINT (documented)
Runtime persistence + real omo task require the local devcontainer = the forbidden 15GB pull. Config committed (shutdownAction:none, GPU runArgs); omo validated in-image via CI; exact runtime commands recorded for a capable-hardware session.

## Final leftover state
- ghcr drill versions deleted via API (delete:packages via gh token — no browser PAT was ultimately needed)
- One June version undeletable (public >5000 downloads, GitHub policy — pre-existing)
- release branch kept; no e2e tags/releases remain
