# Plan: size-opt-pipeline
Updated: 2026-06-14
Research: bg_7afee6a9 (deployment), bg_9aeab9a8 (size est)

## Approach
Optimize the .so size and wire the full pipeline. The .so bundles
Arrow(core+parquet+compute)+QuantLib (no AWS SDK now). Stripped .so
expected ~50-80MB (research bg_9aeab9a8 minus the S3/AWS-SDK contribution).
PyArrow adds ~30-40MB to the image but isn't part of the .so.

## Size levers (apply in order)
1. MinSizeRel (`-Os`) build type for the .so + deps.
2. `-ffunction-sections -fdata-sections` + `-Wl,--gc-sections` (dead-code).
3. LTO (`-DCMAKE_INTERPROCEDURAL_OPTIMIZATION=ON`) — cross-module DCE.
   Watch: LTO link needs >4GB RAM; GCC 16 from-source may need more.
4. `strip --strip-unneeded` the .so — NOTE: use `--strip-unneeded` NOT
   `--strip-all` (must preserve the PyInit_ dynamic symbol + dynamic
   symbol table for CPython's import). Verify `objdump -T | grep PyInit`
   still present after strip.
5. UPX: NOT recommended for .so files (breaks CPython loading + adds
   decompression overhead). OFF.

## Size budget
- .so target: ≤ 80 MB stripped (without S3/AWS-SDK, realistically 50-70MB).
- Full image (.so + PyArrow + base): ≤ 200 MB.
- Enforce: `test $(stat -c%s sum_columns*.so) -lt 83886080`

## Steps
- [ ] Containerfile: ARG BUILD_TYPE=MinSizeRel (was Release).
- [ ] profiles/al2023: build_type=MinSizeRel.
- [ ] CMakeLists.txt (task 002): add INTERPROCEDURAL_OPTIMIZATION on the
      sum_columns target (and on Arrow/QuantLib via Conan toolchain if
      feasible — may slow the dep build significantly; test tradeoff).
- [ ] Builder stage: `strip --strip-unneeded sum_columns*.so` post-build.
      AUDIT: `objdump -T sum_columns*.so | grep PyInit_sum_columns` present.
- [ ] Measure + record pre-strip / post-strip / post-gc sizes in Notes.
- [ ] Makefile targets: `build` (conan+cmake→.so) / `test` (lambda-python
      test stage + RIE) / `ci` (build+test+size-check) / `clean`.
- [ ] `.github/workflows/ci.yml`:
      - on push (paths: src/**, conanfile.py, Containerfile, recipes/**,
        profiles/**, handler.py, data/**) + weekly cron.
      - job: checkout → `podman build --target test` with GCC-16 layer
        cache (`actions/cache` keyed on Containerfile GCC-stage hash) →
        assert test stage RUN assertions passed → assert .so size budget.
      - matrix: x86_64 only for v1.
      - `--provenance=false` if using buildx for any ECR push step.
- [ ] Document cached-path build time in Notes.

## Notes
- A pybind11 .so CANNOT be UPX'd (CPython dlopen rejects it). Document.
- If .so > 80MB after all levers: the candidates for reduction are
  Parquet→Thrift (~5MB) and QuantLib (~15-25MB). Flag to user before
  cutting features.
- LTO on Arrow's full build is very slow (~2x link time); consider LTO
  on ONLY the sum_columns TU, not the deps. Test both.
- GH Actions runners: `ubuntu-latest` has podman via apt; or use
  `docker build` (Containerfile is Docker-compatible).
