# C++26 AWS Lambda Static Library — Initial Research

> **Date**: June 13, 2026
> **Status**: Refined scope (v3) — Gandiva/LLVM analysis complete
> **Goal**: Production-grade static library for AWS Lambda containing Arrow C++ (Parquet, ORC, Flight, S3, Gandiva) + QuantLib, buildable locally in Docker and GitHub Actions, testable against real Lambda images.
>
> **Refined Scope**:
> - Produce a **static library** (`.a`), not a deployable Lambda function
> - Build locally in **Docker** and in **GitHub Actions**
> - Local test/debug using actual **Lambda container image** with Runtime Interface Emulator
> - Parametric Dockerfile for **different Lambda base images** (`ARG BASE_IMAGE`)
> - Static library contains: **Arrow C++** (Parquet, ORC, Flight, S3, Gandiva) + **QuantLib**

---

## Table of Contents

1. [Compiler & Language](#1-compiler--language)
2. [AWS Lambda Environment](#2-aws-lambda-environment)
3. [Deployment Strategy](#3-deployment-strategy)
4. [Library Analysis](#4-library-analysis)
5. [Static Linking Constraints](#5-static-linking-constraints)
6. [Build Infrastructure](#6-build-infrastructure)
7. [Local Development & Testing](#7-local-development--testing)
8. [Known Conflicts & Risks](#8-known-conflicts--risks)
9. [Existing Projects & References](#9-existing-projects--references)
10. [Open Questions for Refined Scope](#10-open-questions-for-refined-scope)

---

## 1. Compiler & Language

### GCC 16.1 — Released April 30, 2026

GCC 16.1 is available for download from `https://sourceware.org/pub/gcc/releases/gcc-16.1.0/`.

#### C++26 Feature Support in GCC 16

| Feature | Status | Flag |
|---|---|---|
| Reflection (P2996R13) | ✅ Implemented | `-std=c++26 -freflection` |
| Reflection Annotations (P3394R4) | ✅ | `-freflection` |
| Contracts (P2900R14) | ✅ | `-std=c++26` |
| Expansion Statements (P1306R5) | ✅ | `-std=c++26` |
| `constexpr` exceptions (P3068R5) | ✅ | `-std=c++26` |
| `std::simd` | ✅ | `-std=c++26` |
| `std::inplace_vector` | ✅ | `-std=c++26` |
| `std::optional<T&>` | ✅ | `-std=c++26` |
| `std::copyable_function` / `function_ref` | ✅ | `-std=c++26` |
| `<debugging>` header | ✅ | `-std=c++26` |
| Structured bindings pack (P1061R10) | ✅ | `-std=c++26` |
| Senders/Receivers (P2300) | ❌ Not in libstdc++ | Use NVIDIA/stdexec or Beman/execution |
| Pattern Matching `inspect` (P2688) | ❌ Not implemented | Clang partial only |
| `std::linalg` (P1673) | ❌ Not implemented | — |
| Hazard Pointers/RCU | ❌ Not implemented | — |

#### Critical GCC 16 Changes

- **Default C++ standard changed to C++20** (was C++17 in GCC 15)
- **C++20 library ABI broken** vs GCC 15 — all C++20 components changed
  - Affected: `<atomic>`, `<semaphore>`, `<syncstream>`, `<format>`, `<compare>`, `<variant>`, `<ranges>`
  - **Must recompile everything with GCC 16 — no mixing object files**
- Reflection requires **separate flag** `-freflection` (not enabled by `-std=c++26` alone)
- `std::variant` ABI updated; use `_GLIBCXX_USE_VARIANT_CXX17_OLD_ABI` if needed

#### Building GCC 16 from Source

| Requirement | Value |
|---|---|
| Disk space (build) | ~15 GB minimum, 30 GB recommended |
| RAM | 4 GB minimum, 8 GB recommended |
| Build time (4 cores) | ~30-60 min |
| Build time (2 cores) | ~60-120 min |
| Installed size | ~2-3 GB |
| Prerequisites | GMP ≥6.1, MPFR ≥4.1, MPC ≥1.2, ISL ≥0.18, Binutils ≥2.38 |

**AL2023 does NOT ship GCC 16** — must build from source. Multi-stage Dockerfile recommended.

#### Minimal Build Configuration for Lambda

```bash
../configure \
    --prefix=/usr/local/gcc-16 \
    --enable-languages=c,c++ \
    --disable-multilib \
    --disable-nls \
    --enable-threads=posix \
    --disable-libgcj \
    --disable-libgfortran \
    --disable-libgo \
    --disable-libobjc \
    --disable-libada \
    --disable-libssp \
    --with-system-zlib
```

Sources: [GCC 16 Release](https://gcc.gnu.org/gcc-16/), [GCC 16 Changes](https://gcc.gnu.org/gcc-16/changes.html), [GCC Development Plan](https://gcc.gnu.org/develop.html)

---

## 2. AWS Lambda Environment

### Runtime Options

| Runtime ID | OS | glibc | GCC Default | Deprecation |
|---|---|---|---|---|
| `provided.al2023` | Amazon Linux 2023 | **2.34** | GCC 11 (GCC 14 optional) | Jun 30, 2029 |
| `provided.al2` | Amazon Linux 2 | 2.26 | GCC 7 (GCC 10 optional) | **Jul 31, 2026** |

**Must use `provided.al2023`** — AL2 deprecated in 45 days.

### AL2023 Container Images

| Image | Size | Use |
|---|---|---|
| `public.ecr.aws/lambda/provided:al2023` | <40 MB | Lambda runtime (includes RIE for local testing) |
| `amazonlinux:2023` | ~40 MB | Pure AL2023 (for building, no Lambda runtime) |
| `public.ecr.aws/sam/build-provided.al2023` | — | SAM build image |

### Deployment Constraints

| Resource | Limit |
|---|---|
| Zip deployment (unzipped) | **250 MB** |
| Container image | **10 GB** |
| Lambda layer (per function) | 5 max |
| Individual layer zipped | 50 MB (API), 250 MB (S3) |
| Combined unzipped (function + layers) | **250 MB** |
| /tmp storage | 512 MB – 10,240 MB |
| Timeout | 900 seconds |
| Max memory | 10 GB (standard), 32 GB (Managed Instances) |
| Max vCPUs | ~6 (standard), 16 (Managed Instances) |
| Image manifest (recommended) | <25,400 bytes |

### What's NOT Available

- **SnapStart**: ❌ Not supported for custom runtimes or container images
- **Response streaming**: ❌ Official C++ RIC disables chunked encoding; must fork or write custom RIC
- **Building inside Lambda**: ❌ 15-min timeout; cannot compile this stack

### Lambda Managed Instances (re:Invent 2024)

| Feature | Standard Lambda | Managed Instances |
|---|---|---|
| Max memory | 10 GB | **32 GB** |
| Max vCPUs | ~6 | **16** |
| Init time limit | 130s | **Up to 900s** |
| Cold starts | Yes (microVM) | Reduced (EC2-based) |
| Base image | AL2023 minimal | Bottlerocket |
| File descriptors | 1,024 | **4,096** |

### Container Image Cold Starts

AWS improved container image loading **15x** via block-level dedup/caching ([AWS paper](https://ar5iv.labs.arxiv.org/html/2305.13162)):
- For images >30MB, **containers are faster than ZIP** in cold starts
- AWS base images are proactively cached on worker instances
- For ~2-4GB images, expect **5-15s cold start** (image load + init)
- Keep image manifest under 25,400 bytes (minimize layers)

### AL2023 libstdc++ Versioning Bug (April 2025)

AL2023 updated to GCC 14 alongside GCC 11, causing `GLIBCXX_3.4.30 not found` for binaries built with old GCC 11. **Mitigation**: Pin your AL2023 image version — don't auto-update.

Sources: [Lambda Runtimes](https://docs.aws.amazon.com/lambda/latest/dg/lambda-runtimes.html), [Lambda Quotas](https://docs.aws.amazon.com/lambda/latest/dg/gettingstarted-limits.html), [AL2023 Lambda Runtime](https://aws.amazon.com/blogs/compute/introducing-the-amazon-linux-2023-runtime-for-aws-lambda/), [Container Image Loading Paper](https://ar5iv.labs.arxiv.org/html/2305.13162), [Managed Instances](https://aws.amazon.com/blogs/compute/build-high-performance-apps-with-aws-lambda-managed-instances/)

---

## 3. Deployment Strategy

### Container Image: The Only Viable Path

| Approach | Viable? | Why |
|---|---|---|
| Zip + layers | ❌ | 250 MB limit; your static library alone may exceed this |
| Container image | ✅ **Required** | 10 GB limit accommodates heavy C++ deps |
| Building inside Lambda | ❌ | 15-min timeout vs hours of compilation |
| musl/Alpine static | ❌ | LibTorch incompatible with musl |

### Recommended: Multi-Stage Docker Build

```
Stage 1: GCC 16 build (amazonlinux:2023)
Stage 2: Dependencies (Arrow + QuantLib)
Stage 3: Static library build
Stage 4: Runtime (public.ecr.aws/lambda/provided:al2023)
```

Sources: [Lambda Container Images](https://docs.aws.amazon.com/lambda/latest/dg/images-create.html), [Containers on Lambda Benchmarks](https://aaronstuyvenberg.com/posts/containers-on-lambda)

---

## 4. Library Analysis

### 4.1 QuantLib

| Factor | Detail |
|---|---|
| Current version | 1.43-dev (HEAD) |
| C++ standard | C++17 minimum (enforced). C++20/26 compiles but untested in CI. |
| Dependencies | Boost ≥1.58 (≥1.75 for C++20+). **No Eigen.** `QL_USE_STD_CLASSES=ON` eliminates most Boost library deps. |
| Static build | ✅ `-DBUILD_SHARED_LIBS=OFF` |
| Size | `libQuantLib.a` debug: ~1.2 GB. Stripped release: ~25-35 MB. Selective link: 5-20 MB typical. |
| Modules | All 972 `.cpp` files always compiled. Cannot disable modules via CMake. Linker dead-code elimination is your only size filter. |
| Lambda proven | ✅ AWS HPC Blog (June 2024) — QuantLib Monte Carlo on Lambda + Batch |
| GCC 16 compatibility | No known issues (released 8 weeks ago, no reports yet). Conservative C++17 codebase. |

#### Critical Build Flags

```cmake
-DBUILD_SHARED_LIBS=OFF
-DCMAKE_BUILD_TYPE=MinSizeRel          # -Os optimization
-DQL_USE_STD_CLASSES=ON               # std::shared_ptr, std::any, std::optional
-DQL_BUILD_EXAMPLES=OFF
-DQL_BUILD_TEST_SUITE=OFF
-DQL_ENABLE_TRACING=OFF
-DQL_ERROR_FUNCTIONS=OFF
-DQL_ERROR_LINES=OFF
-DQL_EXTRA_SAFETY_CHECKS=OFF
-DQL_ENABLE_OPENMP=OFF
```

Sources: [QuantLib CMakeLists.txt](https://github.com/lballabio/QuantLib/blob/master/CMakeLists.txt), [AWS HPC Blog](https://aws.amazon.com/blogs/hpc/harnessing-the-scale-of-aws-for-financial-simulations/), [suhasghorp/QuantLib-Lambda](https://github.com/suhasghorp/QuantLib-Lambda)

---

### 4.2 Apache Arrow C++

| Factor | Detail |
|---|---|
| C++ standard | C++20 (required since Arrow 15+) |
| Build philosophy | Minimal by default — all optional components default `OFF` |
| Static build | ✅ `-DARROW_BUILD_STATIC=ON -DARROW_DEPENDENCY_USE_SHARED=OFF` |
| glibc requirement | Arrow ≥13 dropped AL2 support. Use AL2023 (glibc 2.34) |
| GCC 16 | ✅ Builds cleanly. CI tests GCC 15-16 |

#### Module Size Estimates (Stripped Static)

| Module | Estimated Size | Dependencies Pulled In |
|---|---|---|
| Core (IPC) | ~5-10 MB | Boost headers, xsimd, Flatbuffers |
| Parquet | ~+15 MB | Thrift, Snappy/LZ4/ZSTD (compression) |
| ORC | ~+10-20 MB | ORC C++ library, LZ4, ZSTD, Snappy |
| **Flight** | ~+50-100 MB | **gRPC, Protobuf, Abseil, c-ares** |
| **S3** | ~+80-150 MB | **AWS C++ SDK (~10 aws-c-* libs), aws-lc/s2n-tls** |
| **Gandiva** | ~+500 MB+ | **LLVM (22.x), Protobuf** |
| Compute | ~+5 MB | re2, utf8proc |
| CSV | ~+2 MB | — |
| JSON | ~+3 MB | RapidJSON |

#### Full Heavy Build Estimated Total

| Component | Static `.a` Size | Stripped Binary Contribution |
|---|---|---|
| Arrow core + compute + ipc | ~30-50 MB | ~15-25 MB |
| Parquet + Thrift | ~15 MB | ~8 MB |
| ORC (v2.2.1) | ~10 MB | ~5 MB |
| Flight + gRPC (v1.76) + Protobuf (v31.1) + Abseil + c-ares | ~40-60 MB | ~20-30 MB |
| S3 + AWS SDK (v1.11.778) + CRT stack (13 libs) + aws-lc + s2n-tls | ~50-80 MB | ~25-40 MB |
| **Gandiva + LLVM** | ~200-400 MB | ~50-100 MB |
| Compression (lz4, snappy, brotli, zstd, zlib, bz2) | ~15 MB | ~8 MB |
| QuantLib (stripped, selective link) | ~25-35 MB | ~5-20 MB |
| **GRAND TOTAL (all modules + QuantLib)** | **~385-675 MB** | **~130-210 MB** |

**Total stripped binary with all modules: ~130-210 MB**. This fits within Lambda's 250 MB zip limit marginally, but **container image (10 GB) is the safe path** given QuantLib's selective linking unpredictability.

#### Full Transitive Dependency Tree (~35 unique libraries)

```
Static Library
├── Arrow core + compute + ipc + csv + json
│   ├── Boost (headers), xsimd, utf8proc, re2, RapidJSON
│   └── Compression: zlib, bz2, brotli, lz4, snappy, zstd
├── Parquet → Thrift
├── ORC (v2.2.1) → Protobuf (v31.1) [shared with Flight]
├── Flight + Flight SQL
│   ├── gRPC (v1.76.0) → c-ares, Abseil (20250127.0), re2 [shared]
│   ├── Protobuf (v31.1) [shared with ORC]
│   └── Substrait (v0.44.0) [for Flight SQL]
├── S3 → aws-sdk-cpp (v1.11.778)
│   ├── 5 SDK modules: s3, core, identity-management, sts, cognito-identity
│   └── CRT stack (13 libs): aws-c-s3, aws-c-io, aws-c-http, aws-c-auth,
│       aws-c-cal, aws-c-compression, aws-c-event-stream, aws-c-mqtt,
│       aws-c-sdkutils, aws-c-common, aws-checksums, aws-lc, s2n-tls
├── Gandiva → LLVM (18.x-22.x) [SYSTEM DEP — must pre-install]
│   └── Components: analysis, bitreader, core, ipo, linker, native, orcjit, target, passes
└── QuantLib → Boost headers
```

**Shared dependencies work fine**: Protobuf is shared between Flight and ORC; re2 is shared between Gandiva, Compute, and gRPC. Arrow builds them once.

**All modules coexist**: Arrow CI's `ubuntu-22.04-cpp.dockerfile` builds ALL modules together with `ARROW_BUILD_STATIC=ON`. No mutual exclusions found.

#### Critical Build Flags for All Modules

```cmake
-DCMAKE_BUILD_TYPE=Release
-DARROW_BUILD_SHARED=OFF
-DARROW_BUILD_STATIC=ON
-DARROW_BUILD_TESTS=OFF
-DARROW_BUILD_BENCHMARKS=OFF
-DARROW_DEPENDENCY_SOURCE=BUNDLED
-DARROW_DEPENDENCY_USE_SHARED=OFF
-DARROW_PARQUET=ON
-DARROW_ORC=ON
-DARROW_FLIGHT=ON
-DARROW_S3=ON
-DARROW_GANDIVA=ON
-DARROW_COMPUTE=ON
-DARROW_CSV=ON
-DARROW_JSON=ON
-DARROW_WITH_SNAPPY=ON
-DARROW_WITH_LZ4=ON
-DARROW_WITH_ZSTD=ON
-DARROW_WITH_ZLIB=ON
-DARROW_WITH_RE2=ON
-DARROW_WITH_UTF8PROC=ON
-DARROW_JEMALLOC=OFF
-DARROW_MIMALLOC=OFF
-DARROW_WITH_BACKTRACE=OFF
-DARROW_PYTHON=OFF
-Dxsimd_SOURCE=BUNDLED
```

#### ⚠️ Gandiva + LLVM: Detailed Analysis

**LLVM is a SYSTEM dependency, NOT bundled by Arrow.** Arrow uses `find_package(LLVM)` to discover a pre-installed LLVM (supports versions 7 through 22.1; recommend LLVM 18 or 19).

Gandiva requires JIT compilation — there is NO AOT (ahead-of-time) mode. It uses LLVM's ORC JIT (LLJIT) to compile Arrow expressions to native machine code at runtime. JIT is architecturally fundamental to Gandiva.

| Factor | Value |
|---|---|
| LLVM components needed | analysis, bitreader, core, ipo, linker, native, orcjit, target, passes |
| LLVM static `.a` size (all components) | ~50-90 MB |
| Gandiva + LLVM contribution to stripped binary | ~50-100 MB |
| LLVM build time | 30-60 min (4-8 cores), 60-120 min (2 cores) |
| LLVM build memory | **12-16 GB peak** |
| Gandiva build time | 20-40 min additional |
| Gandiva deprecation status | **NOT deprecated** but low maintenance activity (primary user: Dremio) |

**Critical CMake flags for Gandiva static**:
```cmake
-DARROW_GANDIVA=ON
-DARROW_LLVM_USE_SHARED=OFF              # Force static LLVM (default is shared since GH-37410)
-DARROW_GANDIVA_STATIC_LIBSTDCPP=ON     # Bundle libstdc++/libgcc into the static lib
-DARROW_WITH_RE2=ON                      # Required (auto-enabled with Gandiva)
-DARROW_WITH_UTF8PROC=ON                # Required (auto-enabled with Gandiva)
-DLLVM_DIR=/path/to/llvm/lib/cmake/llvm # Point to system LLVM
```

**JIT cold start impact**: Gandiva's LLVM initialization + JIT compilation of expressions will add **multi-second overhead** to Lambda cold starts. Gandiva has a caching mechanism (`GandivaObjectCache`) that serializes compiled object code to disk, avoiding recompilation on subsequent runs — but first invocation per cold start is expensive.

**LLVM must be pre-installed in the build Docker image**. On Ubuntu: `apt install llvm-18-dev`. On AL2023: build from source (adds another 30-60 min). Consider caching the LLVM build as a separate Docker layer.

Sources: [Arrow CMakeLists.txt](https://github.com/apache/arrow/blob/main/cpp/CMakeLists.txt#L176-L193), [FindLLVMAlt.cmake](https://github.com/apache/arrow/blob/main/cpp/cmake_modules/FindLLVMAlt.cmake), [Gandiva engine.cc](https://github.com/apache/arrow/blob/main/cpp/src/gandiva/engine.cc#L224-L261), [GH-37410](https://github.com/apache/arrow/issues/37410), [Arrow CMakePresets.json (JNI static build)](https://github.com/apache/arrow/blob/main/cpp/CMakePresets.json#L627-L656)

#### Arrow + QuantLib Interop

No known conflicts. Both use different dependency trees. QuantLib uses Boost headers; Arrow also uses Boost headers — potential version conflict if mismatched. Build both from the same source tree or ensure compatible Boost versions.

Sources: [Arrow C++ Build Docs](https://arrow.apache.org/docs/dev/developers/cpp/building.html), [Arrow DefineOptions.cmake](https://github.com/apache/arrow/blob/master/cpp/cmake_modules/DefineOptions.cmake), [Arrow versions.txt](https://github.com/apache/arrow/blob/master/cpp/thirdparty/versions.txt)

---

### 4.3 PyTorch / LibTorch (Future Consideration)

| Factor | Detail |
|---|---|
| C++ standard | C++17 |
| Static build | ⚠️ Removed from official distribution. Must build from source with `-Wl,--whole-archive` |
| Size (CPU minimal) | ~30 MB (torchlambda pattern) |
| GCC compatibility | GCC 11-13 safest. **GCC 16 NOT recommended** |
| musl/Alpine | ❌ Broken — requires glibc |
| TorchScript status | ⚠️ Deprecated (unmaintained 4-5 years). ExecuTorch is the recommended path |
| ExecuTorch alternative | 🔮 50KB base runtime, AOT compiled, selective build. Linux experimental |

#### Arrow + LibTorch Interop Issues

Known conflicts: shared `variant.h` duplication, `shared_ptr` ref-count corruption via `c10` weak symbols. Solutions: static-link Arrow, build both from same compiler, or separate into different Lambda functions.

Sources: [pytorch#22447](https://github.com/pytorch/pytorch/issues/22447), [pytorch#159947](https://github.com/pytorch/pytorch/issues/159947), [torchlambda](https://github.com/szymonmaszke/torchlambda), [ExecuTorch](https://github.com/pytorch/executorch)

---

## 5. Static Linking Constraints

### glibc Version Targeting

Build environment must match or be older than Lambda runtime:
- AL2023 = glibc 2.34
- Building on Ubuntu 24.04 (glibc 2.39) → binaries **will fail** on Lambda if they reference newer symbols
- Building on AL2023 Docker (glibc 2.34) → ✅ perfect match

### musl-libc Static: Not Viable for This Stack

| Library | musl Compatibility |
|---|---|
| Arrow C++ | ⚠️ Partial — some features work |
| QuantLib | ⚠️ Compiles but untested |
| LibTorch | ❌ **Broken** — requires glibc-specific features |

### Lambda Layers: Not Viable

250 MB combined unzipped limit kills the Layers approach for heavy C++ libs.

### AL2023 libstdc++ Symbol Versioning Bug

April 2025 update caused `GLIBCXX_3.4.30 not found`. Pin AL2023 image version.

Sources: [awslabs/aws-lambda-cpp README](https://github.com/awslabs/aws-lambda-cpp), [container-images#132](https://github.com/amazonlinux/container-images/issues/132), [Alpine Static Linking](https://build-your-own.org/blog/20221229_alpine/)

---

## 6. Build Infrastructure

### Recommended: Multi-Stage Docker Build

```dockerfile
# Stage 1: Build GCC 16 on AL2023
FROM amazonlinux:2023 AS gcc-build
RUN dnf install -y gcc gcc-c++ make ... && \
    curl -O gcc-16.1.0.tar.xz && ./build-gcc.sh

# Stage 2: Build all dependencies
FROM gcc-build AS deps-build
COPY thirdparty/ /src/
RUN build-arrow.sh    # Arrow with all modules
RUN build-quantlib.sh # QuantLib

# Stage 3: Build static library
FROM deps-build AS lib-build
COPY src/ /app/
RUN cmake -DBUILD_SHARED_LIBS=OFF ... && make

# Stage 4: Runtime (parametric base image)
ARG BASE_IMAGE=public.ecr.aws/lambda/provided:al2023
FROM ${BASE_IMAGE} AS runtime
COPY --from=lib-build /app/lib/liblambda_cpp26.a /opt/lib/
COPY --from=lib-build /app/include/ /opt/include/
```

### Multi-Architecture Support

```bash
docker buildx build --platform linux/amd64,linux/arm64 ...
```

### GitHub Actions Pattern

```yaml
jobs:
  build:
    runs-on: ubuntu-latest
    strategy:
      matrix:
        arch: [x86_64, arm64]
        base: [al2023, al2]
    steps:
      - uses: actions/checkout@v4
      - name: Build static library
        run: docker build --build-arg BASE_IMAGE=... .
      - name: Push to ECR
        run: ...
```

---

## 7. Local Development & Testing

### Lambda Runtime Interface Emulator (RIE)

RIE is a lightweight Go HTTP server that proxies Lambda's Runtime API. Available in three patterns:

**Pattern A: RIE in Dockerfile (simplest for dev)**:
```dockerfile
ADD https://github.com/aws/aws-lambda-runtime-interface-emulator/releases/latest/download/aws-lambda-rie /usr/local/bin/aws-lambda-rie
RUN chmod +x /usr/local/bin/aws-lambda-rie
```

**Pattern B: Smart entrypoint.sh (best — auto-detects local vs Lambda)**:
```bash
#!/usr/bin/env bash
set -euo pipefail
if [ -n "${AWS_LAMBDA_RUNTIME_API:-}" ]; then
  exec ./bootstrap "$@"        # Running inside Lambda
else
  exec /usr/local/bin/aws-lambda-rie ./bootstrap "$@"  # Running locally
fi
```

**Pattern C: RIE sidecar (Docker Compose)**:
Build a tiny RIE-only container, share binary via named volume.

### Docker Compose Architecture

```yaml
services:
  cpp-builder:
    build:
      context: .
      dockerfile: docker/Dockerfile.build
    command: tail -f /dev/null  # keep alive
    volumes:
      - build-artifacts:/opt/deps

  lambda-rie:
    build:
      context: .
      dockerfile: docker/Dockerfile.runtime
    volumes:
      - build-artifacts:/opt/deps:ro
    ports:
      - "9000:8080"
    environment:
      _LAMBDA_SERVER_PORT: 8080
      AWS_LAMBDA_FUNCTION_TIMEOUT: 30

  lambda-test:
    build:
      context: tests
    depends_on: [lambda-rie]
    command: ./run_integration_tests.sh
```

### Debugging with GDB

```bash
docker run --cap-add=SYS_PTRACE --security-opt seccomp=unconfined -p 9000:8080 lambda-debug
```

VSCode `launch.json` for remote attach:
```json
{
  "name": "Attach to Lambda (gdbserver)",
  "type": "cppdbg",
  "request": "attach",
  "program": "/var/task/bootstrap",
  "MIMode": "gdb",
  "miDebuggerServerAddress": "localhost:2159",
  "stopAtEntry": true
}
```

**SAM CLI debugging (`sam local invoke -d`) is NOT supported for `provided.al2023`/`provided.al2`** — use Docker Compose + gdbserver directly.

### Multi-Arch Considerations

**Lambda does NOT support multi-arch manifest images.** Each function image targets exactly one architecture. Build separate images and tag them differently:
- `public.ecr.aws/lambda/provided:al2023-x86_64`
- `public.ecr.aws/lambda/provided:al2023-arm64`

For GitHub Actions: use `docker/setup-qemu-action` + `docker/setup-buildx-action` + `docker/build-push-action` with `cache-from: type=gha`.

Sources: [aws-lambda-runtime-interface-emulator](https://github.com/aws/aws-lambda-runtime-interface-emulator), [northwood-labs pattern](https://github.com/northwood-labs/local-lambda-environments-with-go), [rusterman/aws-lambda-cpp-sam](https://github.com/rusterman/aws-lambda-cpp-sam), [aws-sam-cli#7291](https://github.com/aws/aws-sam-cli/issues/7291)

---

## 8. Known Conflicts & Risks

### Risk Matrix

| Risk | Severity | Likelihood | Mitigation |
|---|---|---|---|
| GCC 16 ABI incompatibility with heavy libs | High | Medium | Build all deps with GCC 16; no mixing |
| Gandiva JIT cold start penalty (multi-second) | High | **High** | `GandivaObjectCache` for compiled expression caching; Provisioned Concurrency; or drop Gandiva for Compute+Acero |
| LLVM build memory (12-16 GB peak) | Medium | **High** | Use large CI runners (t3.2xlarge+); GitHub Actions large runners; or pre-built LLVM image |
| Gandiva + LLVM build failure in CI | High | Medium | Pin LLVM 18 or 19; cache LLVM Docker layer; use Arrow CI's proven config |
| glibc mismatch (build vs Lambda) | High | Low | Build in AL2023 Docker; pin image version (avoid AL2023 GCC 14 libstdc++ bug) |
| Container image cold start >10s | Medium | High | Provisioned Concurrency; Lambda Managed Instances; keep only needed modules |
| Arrow S3 + AWS SDK version conflicts | Medium | Low | Use bundled deps (`AWSSDK_SOURCE=BUNDLED`, `ARROW_DEPENDENCY_SOURCE=BUNDLED`) — Arrow CI proven |
| Gandiva low maintenance / deprecation risk | Medium | Medium | Monitor Arrow CHANGELOG; primary user (Dremio) may diverge; Compute+Acero is the safer path |
| Total build time >2h first build | Low | **High** | Aggressive Docker layer caching; separate CI jobs for deps vs app; weekly scheduled full rebuilds |
| LLVM as system dep on AL2023 | Medium | **High** | AL2023 lacks LLVM packages; must build from source or use Ubuntu-based build stage with glibc targeting |

### C++ Runtime Consideration (aws-lambda-cpp)

The official C++ RIC is **experimental** and has limitations:
- No response streaming support (chunked encoding disabled)
- Single-threaded event loop
- C++11 minimum — compatible with C++26 consumer code
- 463 stars, last release Dec 2024

---

## 9. Existing Projects & References

| Project | Stars | Relevance |
|---|---|---|
| [awslabs/aws-lambda-cpp](https://github.com/awslabs/aws-lambda-cpp) | 463 | Official C++ Lambda Runtime Interface Client |
| [szymonmaszke/torchlambda](https://github.com/szymonmaszke/torchlambda) | 126 | LibTorch + Lambda, ~30MB static binary (archived) |
| [rusterman/aws-lambda-cpp-sam](https://github.com/rusterman/aws-lambda-cpp-sam) | 2 | Best lifecycle framework (Docker build/test/deploy) |
| [tuplex/tuplex](https://github.com/tuplex/tuplex) | — | Heavy C++ (LLVM+Arrow) on Lambda |
| [spcl/serverless-benchmarks](https://github.com/spcl/serverless-benchmarks) | — | Academic C++ Lambda benchmarks |
| [spcl/cppless](https://github.com/spcl/cppless) | — | Single-source C++ → Lambda (custom Clang fork) |
| [cloudfuse-io/lab-cpp](https://github.com/cloudfuse-io/lab-cpp) | — | Arrow C++ on Lambda experiments |
| [TheLartians/ModernCppStarter](https://github.com/TheLartians/ModernCppStarter) | 5,339 | Modern CMake template (adaptable for Lambda) |

### What Doesn't Exist (Greenfield Opportunities)

- C++26 Lambda static library with Arrow+QuantLib
- Parametric multi-base-image Lambda Docker build
- CDK/CDKTF construct for C++ Lambda
- Conan/vcpkg integration for Lambda deps

---

## 10. Resolved Questions (Previously Open)

> **Scope**: Static library containing Arrow C++ (Parquet, ORC, Flight, S3, Gandiva) + QuantLib.
> **Build**: Docker + GitHub Actions, local Lambda image testing, multi-base-image support.

### Q1: Can Gandiva build statically with LLVM in Docker? What's the actual size?

**Resolved**: Yes. Arrow CI builds all modules with `ARROW_BUILD_STATIC=ON` including Gandiva. LLVM is a **system dependency** (not bundled) — must pre-install (e.g., `apt install llvm-18-dev`). The JNI static build preset (`ninja-release-jni-linux`) is the reference configuration. Gandiva + LLVM adds ~50-100 MB to a stripped binary. Total estimated stripped binary with ALL modules: ~130-210 MB. Container image (10 GB) is the safe deployment path.

### Q2: Any conflicts between Flight (gRPC), S3 (AWS SDK), and Gandiva (LLVM) in a single static build?

**Resolved**: No conflicts found. Arrow CI builds all modules together in `ubuntu-22.04-cpp.dockerfile`. Shared dependencies (Protobuf between Flight/ORC, re2 between Gandiva/Compute/gRPC) are built once. Key caveats: gRPC static requires `ARROW_BUILD_STATIC=ON` (hard constraint); Gandiva defaults to shared LLVM since GH-37410, so `-DARROW_LLVM_USE_SHARED=OFF` is mandatory.

### Q3: Total build time estimate for the full stack?

**Resolved**: First build (no cache): **2-4 hours** (GCC 16: 30-60 min, LLVM: 30-60 min, Arrow+Gandiva: 30-60 min, QuantLib: 20-45 min). Cached incremental build: **5-15 minutes**. Build memory peak: **12-16 GB** (during LLVM compilation).

### Q4: Can LLVM be cached across CI runs?

**Resolved**: Yes. Best strategy: Build LLVM in a dedicated Docker layer (cached via `docker buildx --cache-from/to`). Alternatively, pre-build an LLVM Docker image and use it as the build stage base (`FROM my-llvm:18 AS builder`). GitHub Actions `actions/cache` can cache Docker layers across runs. Arrow CI uses `ccache` for C++ recompilation caching.

### Design Decisions Needed

1. **Gandiva necessity**: Gandiva requires JIT (no AOT mode), adds 50-100 MB, 30-90 min build time, and multi-second cold start penalty from LLVM initialization. **Arrow Compute (`ARROW_COMPUTE`) + Acero (`ARROW_ACERO`) is a zero-LLVM alternative** for expression evaluation. Consider Gandiva only if JIT-compiled SQL expressions are a hard requirement.

2. **Flight necessity**: Adds gRPC (~50-100 MB). In Lambda's short-lived function model, Arrow IPC format + direct S3/Lambda invocation may suffice. Flight is needed for streaming query results between distributed functions.

3. **S3 filesystem**: Adds AWS C++ SDK (~80-150 MB) with 13 CRT libs. Alternative: Use Arrow IPC and the AWS SDK directly in application code.

4. **Consumer compiler**: If the static lib is built with GCC 16, all code must use the same GCC 16 C++20 ABI. Consumers must link with GCC 16 (or GCC 16's libstdc++ for C++17-only code). No mixing with GCC 14/15 object files for C++20 code.

5. **LLVM installation on AL2023**: AL2023 doesn't have LLVM in default repos. Options: (a) build LLVM from source in Docker (adds 30-60 min), (b) use Ubuntu-based build image (different glibc — must be careful), (c) use LLVM apt.llvm.org PPA.

---

## Appendix A: Sources

- [GCC 16 Release](https://gcc.gnu.org/gcc-16/) and [Changes](https://gcc.gnu.org/gcc-16/changes.html)
- [AWS Lambda Custom Runtime](https://docs.aws.amazon.com/lambda/latest/dg/runtimes-custom.html)
- [Lambda Runtimes](https://docs.aws.amazon.com/lambda/latest/dg/lambda-runtimes.html)
- [Lambda Quotas](https://docs.aws.amazon.com/lambda/latest/dg/gettingstarted-limits.html)
- [Container Images](https://docs.aws.amazon.com/lambda/latest/dg/images-create.html)
- [Ephemeral Storage](https://docs.aws.amazon.com/lambda/latest/dg/configuration-ephemeral-storage.html)
- [AL2023 C/C++](https://docs.aws.amazon.com/linux/al2023/ug/c-cplusplus.html)
- [Lambda AVX2](https://docs.aws.amazon.com/lambda/latest/dg/runtimes-avx2.html)
- [Managed Instances](https://docs.aws.amazon.com/lambda/latest/dg/lambda-managed-instances-execution-environment.html)
- [SnapStart](https://docs.aws.amazon.com/lambda/latest/dg/snapstart.html)
- [Lambda Container Image Loading (Paper)](https://ar5iv.labs.arxiv.org/html/2305.13162)
- [Containers on Lambda Benchmarks](https://aaronstuyvenberg.com/posts/containers-on-lambda)
- [On-demand Container Loading](https://aaronstuyvenberg.com/posts/containers-on-lambda-pt-two)
- [awslabs/aws-lambda-cpp](https://github.com/awslabs/aws-lambda-cpp)
- [QuantLib](https://github.com/lballabio/QuantLib)
- [Apache Arrow C++](https://arrow.apache.org/docs/dev/developers/cpp/building.html)
- [PyTorch LibTorch](https://pytorch.org/) and [ExecuTorch](https://github.com/pytorch/executorch)
- [torchlambda](https://github.com/szymonmaszke/torchlambda)
- [AWS HPC Blog — QuantLib on Lambda](https://aws.amazon.com/blogs/hpc/harnessing-the-scale-of-aws-for-financial-simulations/)
- [PyTorch Static Linking Master Bug #21737](https://github.com/pytorch/pytorch/issues/21737)
- [Arrow GLIBC Support #38373](https://github.com/apache/arrow/issues/38373)
- [Arrow + LibTorch Conflicts #28341](https://github.com/apache/arrow/issues/28341)
- [AL2023 libstdc++ Bug #132](https://github.com/amazonlinux/container-images/issues/132)
- [Arrow CMakeLists.txt (LLVM versions)](https://github.com/apache/arrow/blob/main/cpp/CMakeLists.txt#L176-L193)
- [Arrow FindLLVMAlt.cmake](https://github.com/apache/arrow/blob/main/cpp/cmake_modules/FindLLVMAlt.cmake)
- [Arrow Gandiva engine.cc (JIT)](https://github.com/apache/arrow/blob/main/cpp/src/gandiva/engine.cc#L224-L261)
- [Arrow GH-37410 (LLVM shared default)](https://github.com/apache/arrow/issues/37410)
- [Arrow CMakePresets.json (JNI static build)](https://github.com/apache/arrow/blob/main/cpp/CMakePresets.json#L627-L656)
- [Arrow CI Dockerfile (all modules)](https://github.com/apache/arrow/blob/main/ci/docker/ubuntu-22.04-cpp.dockerfile)
- [Arrow ThirdpartyToolchain.cmake](https://github.com/apache/arrow/blob/main/cpp/cmake_modules/ThirdpartyToolchain.cmake)
- [Arrow versions.txt](https://github.com/apache/arrow/blob/main/cpp/thirdparty/versions.txt)
- [aws-lambda-runtime-interface-emulator](https://github.com/aws/aws-lambda-runtime-interface-emulator)
- [northwood-labs RIE pattern](https://github.com/northwood-labs/local-lambda-environments-with-go)
- [aws-sam-cli#7291 (debugging not supported for provided)](https://github.com/aws/aws-sam-cli/issues/7291)
