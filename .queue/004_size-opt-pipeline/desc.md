# Task: size-opt-pipeline
Created: 2026-06-14 (revised)
Status: pending
Depends on: 003

## Intent
Apply size optimization to the .so extension and wire the full pipeline
(Makefile + GitHub Actions) so the build → .so → Lambda-Python-test
sequence runs end-to-end with the test as the final gate.

## Context
- Size profile changed: the .so bundles Arrow(core+parquet+compute)+
  QuantLib (no AWS SDK now). Expect ~50-80MB for the .so + ~30-40MB for
  PyArrow in the image. Lambda container limit is 10GB — generous.
- Optimization levers: MinSizeRel, gc-sections, LTO, strip --strip-unneeded
  on the .so. NOTE: a pybind11 .so can be stripped but keep the dynamic
  symbol table (PyInit_ must remain visible) — use `--strip-unneeded` not
  `--strip-all`.
- No GH Actions workflow exists yet (handoff: not-started).

## Scope IN
- MinSizeRel + `-ffunction-sections -fdata-sections` + `-Wl,--gc-sections`
  + LTO on the .so build.
- `strip --strip-unneeded` the .so (preserves PyInit_ dynamic symbol).
- Define + enforce a size budget for the .so.
- Refactor `Makefile`: `build` (conan+cmake → .so) → `test` (lambda-python
  stage + RIE invoke) → `ci` (build+test+size-check) → `clean`.
- `.github/workflows/ci.yml`: checkout → build .so in builder stage →
  test stage → assert sums + size budget.

## Scope OUT
- ECR push / Lambda deploy (future).
- arm64 matrix (x86_64 only for v1).

## Acceptance
- Final .so ≤ agreed size budget.
- `make ci` runs full sequence locally, ends with Lambda-Python test green.
- `.github/workflows/ci.yml` reproduces `make ci` in CI.
