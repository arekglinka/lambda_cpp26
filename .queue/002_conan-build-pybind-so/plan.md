# Plan: conan-build-pybind-so
Updated: 2026-06-14
Research: bg_7afee6a9 (Lambda Python native ext — DEFINITIVE), bg_9aeab9a8 (arrow/conan/gcc16)

## Approach
Build the pybind11 `.so` extension with Arrow(core+parquet+compute)+QuantLib
statically linked INTO it, libpython dynamically linked. Builder stage is
`FROM public.ecr.aws/lambda/python:3.12` to guarantee the CPython 3.12 ABI.
GCC 16.1 built from source inside that stage (user requires C++26);
`-static-libgcc -static-libstdc++` bundles GCC 16's libstdc++ so the .so
runs on the runtime's older libstdc++ without GLIBCXX errors.

## Key decisions (from research bg_7afee6a9)
- **Builder base = `public.ecr.aws/lambda/python:3.12`** (NOT amazonlinux:2023).
  Gives CPython 3.12 headers (`/var/lang/include/python3.12/Python.h`),
  libpython (`/var/lang/lib/libpython3.12.so`), glibc 2.34, dnf.
- **GCC 16 from source** still needed (AL2023 ships GCC 11.2 = C++17 only).
  Build identically to the old Containerfile (lines 20-33), just on the
  lambda/python base.
- **pybind11_add_module(... MODULE ...)** + `find_package(Python ...
  Development.Module)` → links `Python::Module` DYNAMICALLY (required for
  PyInit_), everything else STATIC.
- **`-static-libgcc -static-libstdc++`** on the .so — bundles GCC 16
  libstdc++ → no GLIBCXX_3.4.3x-not-found at runtime. TLS conflict risk
  (pytorch#109923) does NOT apply (no PyTorch co-import).
- **Conan profile**: `compiler=gcc, compiler.version=16,
  compiler.libcxx=libstdc++11, compiler.cppstd=17` for the dep graph.
  The .so TU (our code) overrides to `-std=c++26` via target property.
- **Arrow options**: core + parquet + compute, s3 OFF (Python does S3).
  Parquet pulls thrift; boost stays OFF (`with_boost=False`).
- **OpenSSL**: with S3 OFF, Arrow no longer pins openssl/1.1.1w — can use
  openssl/3.x (lower GCC-16 risk). Confirm in conan install.

## Expected ldd of the final .so (the target)
```
libpython3.12.so.1.0 => /var/lang/lib/libpython3.12.so.1.0
libpthread.so.0 / libdl.so.2 / libutil.so.1 / libm.so.6 / libc.so.6
/lib64/ld-linux-x86-64.so.2
```
NO libstdc++.so.6, NO libgcc_s.so.1, NO libarrow/libparquet/libQuantLib/
libssl — all static inside.

## Steps
- [ ] Rewrite Containerfile builder stage:
      `FROM public.ecr.aws/lambda/python:3.12 AS builder`
      - dnf install: gcc/gcc-c++ (bootstraps GCC 11 for stage-1),
        cmake/ninja (will pip-upgrade), python3.12-devel, diffutils,
        perl-FindBin, gmp/mpfr/libmpc/isl-devel, bison/flex/texinfo/wget,
        zlib-devel/openssl-devel/curl-devel.
      - Build GCC 16.1.0 from source → /opt/gcc16 (same as old lines 20-33).
      - ENV CC/CXX/PATH/LD_LIBRARY_PATH → /opt/gcc16.
      - ENV CFLAGS="-std=gnu17" (or gnu11+fgnu89-inline if termcap reappears —
        but without S3 the tree is smaller; test if needed).
      - pip3.12 install conan>=2.4 cmake>=3.28 ninja>=1.11 pybind11.
      - conan export recipes/arrow + recipes/quantlib.
      - conan install . --build=missing -pr:h al2023.
- [ ] Fix profiles/al2023: left-flush compiler.libcxx/build_type;
      cppstd=17; cflags gnu17 + -Wno-incompatible-pointer-types;
      exelinkflags gc-sections. (NOTE: this is a MODULE not an exe —
      link flags go via CMake target_link_options, profile sharedlinkflags
      may not apply to MODULE; verify.)
- [ ] conanfile.py: remove aws-lambda-cpp, remove s3/gandiva/flight/orc
      options; set arrow parquet=True compute=True s3=False. Remove the
      aws-sdk-cpp requirement. Keep thrift/zlib/lz4/zstd/snappy/brotli
      for parquet compression.
- [ ] src/CMakeLists.txt (task 001 owns the source; here the LINK mechanics):
      ```cmake
      find_package(Python REQUIRED COMPONENTS Interpreter Development.Module)
      find_package(pybind11 REQUIRED)
      find_package(Arrow REQUIRED)
      find_package(Parquet REQUIRED)
      find_package(QuantLib REQUIRED)
      pybind11_add_module(sum_columns MODULE src/sum_columns.cpp)
      target_compile_features(sum_columns PRIVATE cxx_std_26)
      target_link_libraries(sum_columns PRIVATE
          Python::Module pybind11::module
          Arrow::arrow_static Parquet::parquet_static QuantLib::quantlib)
      target_link_options(sum_columns PRIVATE
          -static-libgcc -static-libstdc++ -Wl,--gc-sections)
      set_target_properties(sum_columns PROPERTIES PREFIX "" OUTPUT_NAME sum_columns)
      ```
- [ ] `conan build .` → produces sum_columns.cpython-312-x86_64-linux-gnu.so.
- [ ] AUDIT: `ldd sum_columns*.so` (must match the target ldd above);
      `readelf -d | grep NEEDED` (no libarrow/libstdc++/libssl);
      `python3.12 -c "import sum_columns; print(dir(sum_columns))"`.
- [ ] If openssl breaks under GCC 16: confirm Arrow (no S3) allows
      openssl/3.x; if still pinned 1.1.1w, apply CFLAGS gnu17 mitigation
      from bg_9aeab9a8.
- [ ] Capture passing log tail to .queue/002_*/build-log.txt.

## Notes
- GCC 16 layer (~10 min) caches across iterations — don't touch the
  from-source build lines unless forced.
- The MODULE target type means profile `exelinkflags` may not apply —
  set link options explicitly via target_link_options in CMakeLists.txt.
- pybind11 is header-only; `pip install pybind11` + `find_package` works.
  Alternative: conan `pybind11/2.13.x` recipe — either is fine.
