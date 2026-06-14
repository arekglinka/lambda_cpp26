# Task: conan-build-pybind-so
Created: 2026-06-14 (revised)
Status: pending
Depends on: 001

## Intent
Get `conan install --build=missing` + `cmake --build` to produce the
pybind11 `.so` extension with Arrow(core+parquet+compute) + QuantLib
statically linked into it, libpython dynamically linked. Iterate to
green under GCC 16, pre-applying every known fix from the handoff.

## Context
- Arrow options narrowed: NO s3 → no AWS SDK, no aws-c-* chain. The dep
  tree shrinks dramatically vs. the old plan (was ~25 pkgs with S3; now
  arrow + thrift + zlib/lz4/zstd/snappy/brotli + openssl + boost-headers
  + quantlib). The OpenSSL-1.1.1w GCC-16 risk from the S3 path is GONE
  (no S3 → Arrow may use openssl/3.x; confirm in plan via bg_9aeab9a8).
- Parquet pulls Thrift back. Boost can stay header-only/off
  (`with_boost=False, with_thrift=True` — thrift is a separate Conan pkg).
- The build target is a SHARED MODULE (.so), not an executable. pybind11
  handles the `PyInit_` symbol + libpython linkage.
- GCC-16 layer from prior sessions should be cached.

## Scope IN
- Fix `profiles/al2023` (stray indent, cppstd=gnu17, CFLAGS gnu17 +
  `-Wno-incompatible-pointer-types` for any C deps).
- Ensure Containerfile builder stage has all prior fixes (diffutils,
  perl-FindBin, pip cmake>=3.28) — BUT remove aws-lambda-cpp build step
  (no longer needed) and add CPython 3.12 headers/devel for pybind11.
- `conan install . --build=missing -pr:h al2023` → green.
- `cmake --build` → produces `sum_columns.cpython-312-x86_64-linux-gnu.so`.
- Verify the .so: `ldd` shows libpython + glibc (NO libarrow/libQuantLib/
  libssl — they must be static inside). `readelf -d | grep NEEDED` audit.
- Capture passing log to `.queue/002_*/build-log.txt`.

## Scope OUT
- Lambda runtime container test (task 003).
- Size optimization (task 004).

## Acceptance
- `conan install . --build=missing -pr:h al2023` exits 0.
- `cmake --build` produces the .so with correct CPython 3.12 suffix.
- `ldd sum_columns*.so` shows NO third-party .so (only libpython + glibc).
- The .so imports in CPython 3.12: `python3.12 -c "import sum_columns"`.
