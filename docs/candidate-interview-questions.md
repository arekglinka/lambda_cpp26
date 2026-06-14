# C++26 AWS Lambda Static Library — Candidate Interview Questions

> **Purpose**: Assess whether a candidate can architect, build, and maintain a production-grade C++26 static library for AWS Lambda containing Apache Arrow (Parquet, ORC, Flight, S3, Gandiva) + QuantLib.
>
> **Difficulty**: Senior C++ Engineer / Build & Infrastructure Engineer level.
>
> **Format**: Question first, then answer on next line. Answers are detailed — candidates don't need to match verbatim but should demonstrate understanding of the underlying concepts.

---

## Section 1: AWS Lambda & Container Fundamentals

### Q1: Why must we use container images instead of ZIP deployment for this project?

**Answer**: ZIP deployment has a 250 MB combined unzipped limit (function + all layers). Our static library with Arrow (all modules including Gandiva/LLVM) + QuantLib will likely exceed 1 GB stripped. Container images support up to 10 GB. Additionally, container images allow us to bake a custom GCC 16 compiler into the image, which AL2023 doesn't ship natively. Container images also now have comparable or better cold start performance than ZIP for images >30MB due to AWS's block-level dedup/caching system.

---

### Q2: What Amazon Linux version must we target and why? What glibc version does it use?

**Answer**: We must target Amazon Linux 2023 (`provided.al2023`). AL2 is deprecated as of July 31, 2026. AL2023 uses glibc 2.34 (vs AL2's glibc 2.26). This matters because if we build on a newer system (e.g., Ubuntu 24.04 with glibc 2.39), the binary will reference `GLIBC_2.39` symbols that don't exist on Lambda, causing runtime failures. We must build inside an AL2023 Docker container to ensure ABI compatibility. We should also pin the AL2023 image version to avoid the known libstdc++ symbol versioning bug from the April 2025 GCC 14 update.

---

### Q3: How would you design a Dockerfile that can rebuild for different Lambda base images (AL2023, AL2, custom)?

**Answer**: Use a multi-stage build with a `ARG BASE_IMAGE` parameter:

```dockerfile
ARG BASE_IMAGE=public.ecr.aws/lambda/provided:al2023

# Build stage — use AL2023 for build regardless of target
FROM amazonlinux:2023 AS builder
# ... build everything ...

# Runtime stage — parametric
FROM ${BASE_IMAGE} AS runtime
COPY --from=builder /opt/lib/liblambda_cpp26.a /opt/lib/
COPY --from=builder /opt/include/ /opt/include/
```

Key considerations:
- Build stage should always match the **oldest** glibc target (AL2023 = glibc 2.34) for maximum forward compatibility.
- Runtime stage can swap between `provided:al2023`, `provided:al2`, or even non-AWS images.
- Use `docker build --build-arg BASE_IMAGE=...` to swap targets.
- For multi-arch, use `docker buildx build --platform linux/amd64,linux/arm64`.

---

### Q4: Explain how the Lambda Runtime Interface Emulator (RIE) enables local testing. How would you set up a local dev loop?

**Answer**: The `provided:al2023` base image includes the RIE binary (`/var/runtime/aws-lambda-rie`). When running locally, RIE acts as a stand-in for Lambda's Runtime API — it receives HTTP requests on port 8080 and forwards them to your `bootstrap` executable via the same environment variables (`AWS_LAMBDA_RUNTIME_API`) that Lambda sets.

Local dev loop:
```bash
# Build and run
docker build -t lambda-dev .
docker run -p 9000:8080 -v $(pwd)/src:/var/task lambda-dev

# Test
curl -XPOST http://localhost:9000/2015-03-31/functions/function/invocations \
     -d '{"payload": "data"}'
```

For debugging with GDB, you need `--cap-add=SYS_PTRACE --security-opt seccomp=unconfined`. For VSCode, use a devcontainer with Docker Compose that mounts source volumes and runs the RIE container alongside a build container. The build container compiles on file change; the runtime container immediately reflects changes via volume mounts.

---

## Section 2: C++ Build System & Static Linking

### Q5: You need to build Apache Arrow C++ with Parquet, ORC, Flight, S3, and Gandiva as a static library. What are the heaviest dependencies each module pulls in, and what CMake flags control them?

**Answer**:

| Module | Heavy Dependencies | CMake Flag |
|---|---|---|
| **Parquet** | Thrift, Snappy/LZ4/ZSTD | `ARROW_PARQUET=ON` |
| **ORC** | ORC C++ library, compression libs | `ARROW_ORC=ON` |
| **Flight** | gRPC (~50MB), Protobuf, Abseil, c-ares | `ARROW_FLIGHT=ON` |
| **S3** | AWS C++ SDK (~80-150MB), aws-lc/s2n-tls, 10+ aws-c-* libs | `ARROW_S3=ON` |
| **Gandiva** | LLVM (~500MB-1GB), Protobuf | `ARROW_GANDIVA=ON` |

Critical flags: `ARROW_BUILD_STATIC=ON`, `ARROW_DEPENDENCY_SOURCE=BUNDLED`, `ARROW_DEPENDENCY_USE_SHARED=OFF`. Bundled deps get merged into `libarrow_bundled_dependencies.a`.

The biggest concern is Gandiva requiring a full LLVM build (~500MB-1GB, 30-90 min compile time). Flight pulls in gRPC which is itself large but manageable. S3 pulls in the entire AWS C++ SDK.

---

### Q6: What is the `-Wl,--whole-archive` linker flag and why is it critical when statically linking certain libraries?

**Answer**: The linker normally only includes object files from a static archive (`.a`) that satisfy unresolved symbols. This is called "dead code elimination" and is usually desirable. However, some libraries (notably PyTorch/LibTorch) use **global constructors for dynamic operator registration** — code that runs at program startup to register operators into a global registry.

Without `--whole-archive`, the linker sees no explicit references to these constructors and strips them, causing runtime errors like `"Unknown builtin op: aten::mul"`.

```cmake
target_link_libraries(myapp PRIVATE
    -Wl,--whole-archive ${TORCH_LIBRARIES}
    -Wl,--no-as-needed
    -Wl,--no-whole-archive)
```

This forces the linker to include ALL object files from the archive, preserving the registration constructors. The trade-off is a larger binary.

For our project, this may or may not be needed for Arrow/QuantLib (they don't heavily use global constructor registration), but it's critical if we add LibTorch later.

---

### Q7: How would you minimize the binary size of a static library containing QuantLib?

**Answer**:

1. **Build type**: Use `MinSizeRel` (`-Os`) instead of `Release` (`-O2`). Or `Release` with `-ffunction-sections -fdata-sections` + linker `-Wl,--gc-sections` for dead code elimination.

2. **QuantLib flags**: `QL_USE_STD_CLASSES=ON` (replaces Boost `shared_ptr`/`any`/`optional` with std equivalents), `QL_ENABLE_TRACING=OFF`, `QL_BUILD_TEST_SUITE=OFF`, `QL_BUILD_EXAMPLES=OFF`, `QL_ERROR_FUNCTIONS=OFF`, `QL_ERROR_LINES=OFF`.

3. **Post-build stripping**: `strip --strip-unneeded` removes debug symbols. `strip --strip-all` goes further but may break stack traces.

4. **Selective linking**: QuantLib compiles all 972 `.cpp` files into `libQuantLib.a`, but the linker only pulls in referenced `.o` files. If you only use vanilla option pricing, you might only link 5-20 MB of the 25-35 MB stripped `.a`.

5. **LTO**: `-DCMAKE_INTERPROCEDURAL_OPTIMIZATION=ON` enables Link-Time Optimization, allowing cross-module dead code elimination. Slower build but smaller binary.

---

### Q8: GCC 16 defaults to C++20 and breaks C++20 ABI vs GCC 15. What are the implications for our static library?

**Answer**: GCC 16 changed the ABI representation of C++20 standard library components (atomic, semaphore, format, ranges, variant, etc.) because C++20 support was "experimental" in previous GCC versions. This means:

1. **Cannot mix**: Object files compiled with GCC 15's C++20 cannot link with GCC 16's C++20. You'll get linker errors or subtle runtime bugs.

2. **Everything must be rebuilt**: All dependencies (Arrow, QuantLib, any other libs) must be compiled with the same GCC version. No pre-built packages from AL2023's GCC 11/14 can be mixed with GCC 16-compiled code.

3. **C++17 ABI is stable**: If all code restricts itself to C++17, ABI is compatible across GCC 14/15/16. But Arrow requires C++20, so this doesn't help us.

4. **Practical implication**: Our Docker build must compile GCC 16 from source, then compile Arrow + QuantLib + our code all with that GCC 16. This is a long build (~2-4 hours first time) that must be cached aggressively in CI.

5. **The `--default-to-c++20` flag matters**: Consumers of our static library must also use `-std=c++26` (or `-std=c++20`) with GCC 16, not fall back to the GCC 16 default of C++20 (which is fine, but they must be aware).

---

## Section 3: Dependency Management & Build Pipeline

### Q9: How would you structure a Docker-based build pipeline that compiles GCC 16, Arrow (all modules), and QuantLib — while keeping CI build times reasonable?

**Answer**: Layered Docker builds with aggressive caching:

```dockerfile
# Layer 1: GCC 16 (changes rarely — ~2h build, cache forever)
FROM amazonlinux:2023 AS gcc16
RUN build-gcc-16.sh

# Layer 2: Arrow + Gandiva LLVM (changes rarely — ~1-2h build)
FROM gcc16 AS arrow-build
RUN build-llvm.sh       # ~30-90 min
RUN build-arrow.sh      # ~30-60 min with all modules

# Layer 3: QuantLib (changes rarely — ~20-45 min)
FROM gcc16 AS quantlib-build
RUN build-quantlib.sh

# Layer 4: Our library (changes frequently — seconds-minutes)
FROM arrow-build AS lib-build
COPY --from=quantlib-build /usr/local/lib/ /usr/local/lib/
COPY src/ /app/src/
RUN cmake && make

# Layer 5: Runtime
ARG BASE_IMAGE=public.ecr.aws/lambda/provided:al2023
FROM ${BASE_IMAGE}
COPY --from=lib-build /app/lib/ /opt/lib/
```

CI optimization strategies:
- **Docker layer caching** in GitHub Actions (`actions/cache` for Docker layers, or `docker buildx` with `--cache-from/to`)
- **Separate CI jobs**: One for deps (runs weekly or on Dockerfile change), one for app (runs every PR)
- **CCache**: Mount a ccache volume across builds for header-heavy recompilation
- **Build LLVM once**: LLVM for Gandiva is the longest single build; cache it as a separate Docker layer
- **Parallel builds**: Arrow and QuantLib can be built in parallel (no mutual dependency)

---

### Q10: Arrow S3 pulls in the entire AWS C++ SDK. How do you manage this without bloating the static library with unnecessary AWS services?

**Answer**: Use `ARROW_DEPENDENCY_SOURCE=BUNDLED` which builds only the AWS SDK components that Arrow S3 actually needs. Arrow's CMake configures the AWS SDK with `BUILD_ONLY` to limit the built services. The AWS SDK services pulled in by Arrow S3 are typically: `s3`, `core`, `identity-management`, `sts`, and their transitive `aws-c-*` crypto/TLS dependencies (~80-150 MB stripped).

To further control this, you can inspect Arrow's `ThirdpartyToolchain.cmake` to see exactly which AWS SDK components are required. You cannot use a pre-built AWS SDK — you must build it as part of Arrow's bundled dependency tree to ensure static linking consistency.

If the full S3 filesystem is too large, consider using Arrow's IPC format and the AWS SDK separately (not via Arrow's S3 module), or use `ARROW_S3=OFF` and implement S3 access in application code.

---

### Q11: You need to support both x86_64 and arm64 (Graviton) Lambda functions. What are the CMake and Docker considerations?

**Answer**:

**Docker**:
```bash
docker buildx build --platform linux/amd64,linux/arm64 \
    --build-arg BASE_IMAGE=public.ecr.aws/lambda/provided:al2023 \
    -t lambda-cpp26:latest .
```

**CMake considerations**:
- Use `CMAKE_SYSTEM_PROCESSOR` to detect architecture
- QuantLib: No arch-specific concerns — pure C++ math
- Arrow: SIMD via xsimd auto-detects. Gandiva uses LLVM which handles multi-arch
- Flight/gRPC: Protobuf and gRPC are architecture-agnostic
- AWS SDK: Same for both architectures

**Build considerations**:
- Cross-compilation from x86 to arm64 is possible but painful for C++ (especially with LLVM/Gandiva). Better to **build natively** on each architecture.
- GitHub Actions `ubuntu-24.04-arm` runners are available but slower/more expensive.
- Alternative: Use `docker buildx` with QEMU emulation for arm64 builds on x86 runners. Slower (~2-3x) but no extra runner cost.

**Lambda configuration**:
- x86_64: AVX2 support (via `-mavx2` or `-march=haswell`)
- arm64 (Graviton): NEON + dot-product instructions (via `-mcpu=neoverse-n1` for Graviton2, `-mcpu=neoverse-v1` for Graviton3)
- Graviton is 20% cheaper; arm64 images may have smaller cold starts

---

## Section 4: Architecture & Design Decisions

### Q12: The user wants Gandiva (which requires LLVM) in the static library. What are your concerns, and what would you propose?

**Answer**:

**Concerns**:
1. **Size**: LLVM minimal static build is 500 MB – 1 GB. This dominates the total library size.
2. **Build time**: LLVM takes 30-90 minutes to compile. This is the single longest build step.
3. **Gandiva deprecation**: Gandiva's maintenance status in Arrow is uncertain. The Arrow community has discussed potentially replacing it with Acero/Substrait for expression evaluation.
4. **JIT in Lambda**: Gandiva uses LLVM's JIT compiler. Lambda's Firecracker microVM has limited memory-mapping capabilities. JIT should work but hasn't been widely tested in this environment.
5. **Lambda cold start**: A 1 GB+ library means 5-15 second cold starts just for image loading.

**Proposal**:
- If Gandiva is for **SQL-like expression evaluation** on Arrow data, consider Arrow Acero (`ARROW_ACERO=ON`) as a lighter alternative — it's a push-based query engine without LLVM dependency.
- If Gandiva is specifically needed for its **code-generated expressions**, accept the LLVM cost but:
  - Cache LLVM as a separate Docker layer
  - Build LLVM once in a dedicated CI workflow
  - Consider using LLVM's AOT compilation mode if JIT isn't needed
  - Monitor Arrow's Gandiva roadmap for deprecation signals

---

### Q13: How would you design the public API of the static library so that consumers can link against it without pulling in all transitive dependencies they don't need?

**Answer**:

1. **Static library with selective linking**: Ship a single `.a` file. The linker naturally only pulls in referenced `.o` files. If a consumer only uses QuantLib pricing functions, they don't pay for Gandiva/LLVM code.

2. **Module-separated static libraries**: Ship multiple `.a` files:
   ```
   lib/liblambda_arrow.a         # Arrow core + IPC
   lib/liblambda_arrow_parquet.a # Parquet
   lib/liblambda_arrow_flight.a  # Flight + gRPC
   lib/liblambda_arrow_s3.a      # S3 + AWS SDK
   lib/liblambda_arrow_gandiva.a # Gandiva + LLVM
   lib/liblambda_arrow_orc.a     # ORC
   lib/liblambda_quantlib.a      # QuantLib
   lib/liblambda_runtime.a       # aws-lambda-cpp RIC
   ```
   Consumers link only what they need:
   ```cmake
   target_link_libraries(myapp PRIVATE
       lambda_arrow lambda_arrow_parquet lambda_quantlib lambda_runtime)
   ```

3. **CMake targets**: Provide proper CMake config/package with namespaced imported targets:
   ```cmake
   find_package(lambda_cpp26 REQUIRED COMPONENTS arrow;parquet;quantlib;runtime)
   target_link_libraries(myapp PRIVATE lambda_cpp26::arrow lambda_cpp26::parquet)
   ```

4. **Hidden visibility by default**: Compile with `-fvisibility=hidden` and explicitly export only the public API symbols. This prevents symbol pollution and ensures clean linkage boundaries.

---

### Q14: You're building a static library that includes both Arrow (C++20) and QuantLib (C++17). Both use Boost headers. How do you prevent Boost version conflicts?

**Answer**:

1. **Unified dependency tree**: Build everything from the same dependency source. Use Arrow's bundled Boost or a single FetchContent/ExternalProject Boost version that satisfies both libraries' requirements.

2. **Version selection**: Arrow typically bundles Boost 1.88+. QuantLib requires ≥1.58 (≥1.75 for C++20+). Use the Arrow-bundled version — it satisfies QuantLib's requirements.

3. **Header-only only**: QuantLib with `QL_USE_STD_CLASSES=ON` only needs Boost headers, not Boost libraries. Arrow's bundled Boost is also headers-only for most components. No link-time conflict.

4. **CMake transitive dependency management**:
   ```cmake
   # In our library's CMakeLists.txt
   target_include_directories(lambda_cpp26 PUBLIC
       $<BUILD_INTERFACE:${Boost_INCLUDE_DIRS}>
       $<INSTALL_INTERFACE:include>)
   ```

5. **If conflicts arise**: Use CMake's `find_package(Boost ...)` once at the top level, then pass `Boost_INCLUDE_DIRS` to both Arrow and QuantLib builds via `-DBOOST_INCLUDEDIR=...` and `-DBOOST_ROOT=...`.

---

## Section 5: Operational & Debugging

### Q15: A Lambda function using your static library fails with `GLIBC_2.35 not found` at runtime. How do you diagnose and fix this?

**Answer**:

**Diagnosis**:
1. `ldd` on the binary (locally) to check linked libraries
2. `objdump -T binary | grep GLIBC` to see which symbol versions are referenced
3. `readelf -d binary | grep NEEDED` for dynamic dependencies
4. Check which Docker image was used for building — was it AL2023 (glibc 2.34) or something newer like Ubuntu 22.04 (glibc 2.35)?

**Fix**:
1. **Immediate**: Ensure the build Dockerfile uses `amazonlinux:2023` (not Ubuntu/Debian) as the build image
2. **Verify**: `docker run --rm amazonlinux:2023 ldd --version` shows glibc 2.34
3. **Pin image**: Use a specific AL2023 digest, not a floating tag
4. **If must build on newer system**: Use `-DCMAKE_CXX_FLAGS="-D_GLIBCXX_USE_CXX11_ABI=0"` and link statically against libstdc++ (`-static-libgcc -static-libstdc++`), but this doesn't help with glibc itself
5. **For glibc specifically**: Fully static linking (`-static`) avoids the issue but breaks DNS resolution and has other problems. Better to just build on AL2023.

---

### Q16: Your Lambda function cold starts take 12 seconds. What optimization strategies would you try?

**Answer**:

1. **Diagnose the breakdown**: Is it image loading or init code? Use CloudWatch Logs `InitDuration` metric to separate.

2. **Image loading (Lambda's responsibility)**:
   - Cannot directly optimize, but minimize image layers (keep manifest <25,400 bytes)
   - Use AWS base images (proactively cached by Lambda)
   - Smaller total image = faster load

3. **Init code optimization**:
   - Load models/data lazily (on first invocation) instead of in global scope
   - Defer heavy initialization (Arrow/QuantLib setup) until first use
   - Use `Lambda Managed Instances` (longer init budget: up to 900s for initialization, not counted in billed duration)

4. **Infrastructure**:
   - **Provisioned Concurrency**: Keeps N execution environments warm (~$0.015/GB-hour)
   - **ARM64 (Graviton)**: 13-24% faster cold starts, 20% cheaper
   - **Higher memory**: More memory = more vCPUs = faster image loading

5. **Build optimizations**:
   - Strip the binary (`strip --strip-all`)
   - Use `MinSizeRel` build type
   - Consider UPX (but it can make cold starts WORSE due to decompression overhead — ~35ms penalty)

6. **Separate Lambda functions**: If not all invocations need Gandiva/LLVM, split into two functions — one light (Arrow core + QuantLib) and one heavy (full stack).

---

### Q17: How would you set up GitHub Actions to build, test, and publish this static library for multiple architectures and Lambda base images?

**Answer**:

```yaml
name: Build Lambda C++26 Static Library
on:
  push:
    paths: ['src/**', 'CMakeLists.txt', 'docker/**', 'thirdparty/**']
  schedule:
    - cron: '0 0 * * 0'  # Weekly full rebuild (catches dependency updates)

jobs:
  build-deps:
    runs-on: ubuntu-latest
    strategy:
      matrix:
        arch: [x86_64, arm64]
    steps:
      - uses: actions/checkout@v4
      - uses: docker/setup-buildx-action@v3
      - name: Cache Docker layers
        uses: actions/cache@v4
        with:
          path: /tmp/.buildx-cache
          key: deps-${{ matrix.arch }}-${{ hashFiles('docker/Dockerfile.deps') }}
      - name: Build dependencies image
        run: |
          docker buildx build --platform linux/${{ matrix.arch }} \
            --cache-from type=local,src=/tmp/.buildx-cache \
            --cache-to type=local,dest=/tmp/.buildx-cache-new \
            -f docker/Dockerfile.deps \
            -t ghcr.io/${{ github.repository }}/deps:${{ matrix.arch }} \
            --load .
      - run: mv /tmp/.buildx-cache-new/* /tmp/.buildx-cache/

  build-lib:
    needs: build-deps
    runs-on: ubuntu-latest
    strategy:
      matrix:
        arch: [x86_64, arm64]
    steps:
      - uses: actions/checkout@v4
      - name: Build static library
        run: |
          docker buildx build --platform linux/${{ matrix.arch }} \
            --build-arg DEPS_IMAGE=ghcr.io/${{ github.repository }}/deps:${{ matrix.arch }} \
            -f docker/Dockerfile.lib \
            -t lambda-cpp26:${{ matrix.arch }} .
      - name: Test in Lambda image
        run: |
          docker buildx build --platform linux/${{ matrix.arch }} \
            --build-arg LIB_IMAGE=lambda-cpp26:${{ matrix.arch }} \
            -f docker/Dockerfile.test \
            lambda-cpp26-test:${{ matrix.arch }}
          docker run --rm lambda-cpp26-test:${{ matrix.arch }}
      - name: Upload artifact
        uses: actions/upload-artifact@v4
        with:
          name: lib-${{ matrix.arch }}
          path: build/liblambda_cpp26.a

  publish:
    needs: build-lib
    runs-on: ubuntu-latest
    steps:
      - name: Push multi-arch image to ECR
        run: |
          docker buildx build --platform linux/amd64,linux/arm64 \
            -t $ECR_REPO/lambda-cpp26:${{ github.sha }} \
            --push .
```

Key design decisions:
- **Separate deps and lib builds**: Deps rebuild weekly; lib rebuilds every PR
- **Docker layer caching**: Prevents rebuilding GCC 16 + LLVM on every PR
- **Matrix for arch**: x86_64 and arm64 in parallel
- **Test in actual Lambda image**: Not just unit tests — integration test in `provided:al2023` container with RIE

---

## Section 6: Forward-Looking & Tradeoff Assessment

### Q18: The user mentioned potentially adding PyTorch/LibTorch later. What ABI conflicts exist between Arrow and LibTorch, and how would you prepare for this?

**Answer**:

Known conflicts:
1. **`variant.h` duplication**: Both LibTorch (`c10/util/variant.h`) and Arrow (`arrow/vendored/variant.hpp`) define `MPARK_LIB_HPP` guard. Whichever is included first wins; the other silently fails to compile.
2. **`shared_ptr` ref-count corruption**: LibTorch's `libc10.so` exports weak symbols (`std::_Sp_counted_base`) that override `libstdc++.so`'s versions, corrupting Arrow's shared pointer reference counting.
3. **`_GLIBCXX_USE_CXX11_ABI`**: Must be consistent across all libraries. LibTorch ships two versions (CXX11 ABI and pre-CXX11 ABI).

Preparation strategies:
1. **Static-link Arrow**: A static `.a` avoids shared symbol conflicts entirely. Arrow symbols are resolved at link time, not runtime.
2. **Compiler isolation**: Build LibTorch with GCC 13 (safe for PyTorch), everything else with GCC 16. Use a C ABI boundary between them — no C++ types cross the boundary, only POD structs and `extern "C"` functions.
3. **ExecuTorch over LibTorch**: ExecuTorch (50KB runtime) is PyTorch's recommended path for embedded/static deployment. It has fewer dependencies and no known Arrow conflicts. But it's experimental on Linux desktop.
4. **Process isolation**: Run Arrow and PyTorch in separate Lambda functions, communicate via S3/SQS. Most robust but highest latency.

---

### Q19: Rate your confidence in the following aspects of this project (1-5), and explain your reasoning.

**Answer**: This is open-ended — here's what a strong answer looks like:

| Aspect | Confidence | Reasoning |
|---|---|---|
| Arrow core + Parquet + ORC static build | 5/5 | Well-documented, minimal-by-default CMake, proven in production |
| Arrow Flight (gRPC) static build | 4/5 | gRPC static builds work but are large; Arrow CI tests this |
| Arrow S3 static build | 4/5 | AWS SDK builds bundled, tested in Arrow CI, but large |
| Arrow Gandiva (LLVM) static build | 2/5 | LLVM is notoriously difficult to build statically; Gandiva maintenance uncertain; JIT in Lambda untested |
| QuantLib static build | 5/5 | Conservative codebase, straightforward CMake, proven on Lambda (AWS HPC Blog) |
| GCC 16 + C++26 on Lambda | 4/5 | Works via container image; ABI breaks are manageable if everything is rebuilt together |
| Multi-arch (x86 + arm64) | 3/5 | Native builds work; cross-compilation with LLVM is painful; QEMU emulation is slow |
| Local Lambda testing (RIE) | 4/5 | Well-documented pattern; C++ debugging needs `SYS_PTRACE` capability |
| Sub-10s cold starts | 2/5 | Gandiva+LLVM pushes image to 1GB+; expect 10-15s cold starts without Provisioned Concurrency |
| Total build time <30 min in CI (cached) | 3/5 | Possible with aggressive caching, but LLVM+GCC16 first build is 2-4 hours |

---

### Q20: What questions would you ask the user before starting implementation?

**Answer** (a strong candidate should push back on requirements):

1. **Gandiva**: "Gandiva adds 500MB-1GB and 30-90 min build time via LLVM. Do you specifically need JIT-compiled expressions, or could Arrow Acero (no LLVM dependency) serve your use case?"

2. **Flight vs IPC**: "Arrow Flight adds gRPC (~50-100MB). In a Lambda context where functions are short-lived, do you need Flight's streaming RPC, or would Arrow IPC format with direct Lambda-to-Lambda invocation suffice?"

3. **S3 filesystem**: "Arrow's S3 module adds the entire AWS C++ SDK (~80-150MB). Could you use the AWS SDK directly in application code instead, pulling in only the S3 client?"

4. **Cold start budget**: "With all modules enabled, expect 10-15 second cold starts. What's your acceptable cold start latency? Would you accept Provisioned Concurrency costs?"

5. **GCC version**: "GCC 16 is very new (8 weeks old). QuantLib and Arrow are untested with it. Would you accept GCC 14 (well-tested, C++23, available on AL2023) to reduce risk, with a planned migration to GCC 16 when libraries catch up?"

6. **Binary size budget**: "What's the maximum acceptable container image size? Each heavy module adds significant weight. Gandiva alone could be 1GB."

7. **Testing strategy**: "What does 'test locally' mean to you? Unit tests only, or integration tests running in the actual Lambda container image with RIE?"

8. **Consumer API**: "Will consumers of this static library link against all modules, or will they cherry-pick? This affects whether we ship one `.a` or multiple `.a` files."

---

## Section 7: Real-World Build Breakage (Based on Actual Problems Encountered)

> These questions are drawn from real issues hit during the project build. A strong candidate should recognize the root causes quickly and propose systematic fixes, not just guess patches.

### Q21: You build GCC 16 from source inside a Dockerfile, then run `conan install . --build=missing` which compiles 50+ transitive dependencies. The build fails on `termcap/1.3.1` with "too many arguments to function 'tparam1'". The termcap source has `static char *tparam1();` (empty argument list) as a forward declaration, but calls it with 4 arguments. What is happening, and what is the correct fix?

**Answer**: GCC 15+ changed the default for C code: `-Werror=implicit-int` and `-Werror=implicit-function-declaration` are now hard errors, not warnings. More critically, GCC 16 defaults to C17/C23, where an empty parameter list `()` in a function declaration means **zero arguments** (not "unknown arguments" as in K&R C / C89). When termcap later calls `tparam1(str, str, str, str)`, GCC 16 sees a 0-arg function being called with 4 arguments — a hard error, not a warning.

Why this matters: termcap is a transitive dependency pulled in by readline/editline, which is itself pulled in by something else in the dependency tree. You don't control termcap's source code.

Fix approaches (ranked):
1. **Best**: Set `ENV CFLAGS="-std=gnu11 -fgnu89-inline"` in the Dockerfile. This tells GCC to accept K&R-style empty parameter lists for all C code. This is safe because C code compiled as gnu11 is ABI-compatible with the system C library.
2. **Overkill but thorough**: Patch every affected Conan recipe to add `-std=gnu11` to its CMake build flags. Fragile because new transitive deps may appear.
3. **Wrong**: `-Wno-error=implicit-int` or `-Wno-error=int-conversion`. These are warnings about different issues and don't fix the fundamental problem (empty parameter list semantics changed).

A candidate who immediately identifies the C99 vs C89 empty parameter list semantics difference is strong. One who tries `-Wno-error` flags without understanding the root cause is weaker.

---

### Q22: You add `cmake/[>=3.25 <4]` as a `tool_requires` in your Conan `conanfile.py`. You run `conan install . --build=missing` and snappy (a transitive dependency) still picks up the system CMake 3.20 and fails because CMake 3.20 doesn't support `CMAKE_CXX_STANDARD 26`. Why doesn't the tool_requires propagate to transitive deps?

**Answer**: In Conan 2.x, `tool_requires` in a consumer's `conanfile.py` only applies to the **consumer's own** `build()` method. When Conan builds dependencies with `--build=missing`, each dependency's own recipe controls its build environment. If `snappy`'s ConanCenter recipe doesn't declare `self.tool_requires("cmake/...")`, it falls back to whatever CMake is available on the system PATH.

This is a fundamental limitation of Conan 2.x: tool_requires don't propagate transitively. ConanCenter recipes are inconsistent — some declare cmake as a tool_require, others don't.

Fix approaches:
1. **Most robust**: Install a modern CMake at the **system level** in the Dockerfile (`pip3 install cmake>=3.28`), so ALL builds — Conan-managed and system-managed — pick it up from PATH.
2. **Profile approach**: Add `tools.build:cmake=/path/to/modern/cmake` in the Conan profile's `[conf]` section. This overrides CMake for all recipes that use Conan's CMakeToolchain.
3. **Fragile**: Fork every broken ConanCenter recipe to add the missing `tool_requires`.

A strong candidate understands that Conan 2.x changed propagation semantics from 1.x and knows when to use system-level tools vs. Conan-managed tools. They also recognize that ConanCenter recipe quality is inconsistent and plan for it.

---

### Q23: Your Conan recipe requires `arrow/18.0.0` and the ConanCenter `arrow` recipe exists, but you write a custom recipe under `recipes/arrow/conanfile.py` instead. Give three concrete reasons why the ConanCenter recipe was insufficient for this project.

**Answer**:

1. **ORC module broken**: ConanCenter's `arrow` recipe hardcodes ORC to use shared LLVM (`ARROW_ORC_LLVM_SHARED=ON`), which doesn't work for static linking. You need LLVM built as a static library for Gandiva, and the ConanCenter recipe's CMake configuration forces shared LLVM even when `shared=False` is set.

2. **Stale version**: ConanCenter's `arrow` recipe was stuck on an older Arrow version (17.x or earlier) at the time, missing critical fixes. Arrow 18.0.0 had important changes to the S3 filesystem and Gandiva modules that we needed.

3. **Hardcoded AWS SDK references**: The ConanCenter recipe's `generate()` and `package_info()` methods referenced `aws-c-sdk-cpp` components that don't exist when Arrow builds with bundled dependencies (`ARROW_DEPENDENCY_SOURCE=BUNDLED`). Our custom recipe removes these references to prevent CMake find_package failures.

Bonus: ConanCenter's `quantlib` recipe is stuck at version 1.30 (current stable is 1.38), meaning it's months behind with missing bug fixes and API additions.

A candidate who has real Conan experience will immediately recognize that ConanCenter recipe quality varies wildly and that complex packages (Arrow, LLVM-adjacent) almost always need custom recipes.

---

### Q24: You are building inside a Docker container based on `amazonlinux:2023`. The `aws-lambda-cpp` library is not available on ConanCenter. How do you integrate it, and what CMake configuration do you use so your handler can find it?

**Answer**: Build it from source directly in the Dockerfile (not via Conan), install to a system prefix like `/usr/local`, and use CMake's `find_package` with system search paths:

```dockerfile
# In Containerfile — build and install to /usr/local
RUN cd /tmp && \
    curl -sL https://github.com/awslabs/aws-lambda-cpp/archive/v0.2.6.tar.gz | \
    tar xz && cd aws-lambda-cpp-0.2.6 && mkdir build && cd build && \
    cmake .. -DCMAKE_INSTALL_PREFIX=/usr/local \
            -DBUILD_SHARED_LIBS=OFF \
            -DCMAKE_CXX_STANDARD=26 && \
    cmake --build . && cmake --install .
```

```cmake
# In src/CMakeLists.txt
find_package(aws-lambda-cpp REQUIRED)
# Or since aws-lambda-cpp doesn't ship CMake config:
# find_library(AWS_LAMBDA_RT aws-lambda-runtime PATHS /usr/local/lib)
# find_path(AWS_LAMBDA_RT_INCLUDE aws/lambda-runtime/runtime-api.h PATHS /usr/local/include)
```

The key insight: Conan is not the only dependency management tool. Some libraries are better managed as system-level installs in the Docker image, especially when they're small, infrequently updated, and not available in ConanCenter.

---

### Q25: You run `podman build -f Containerfile` and it fails after 10 minutes with `cmp: command not found` during GCC 16's build of the GFDL documentation (`tm.texi`). What is `cmp`, why is it missing, and why does GCC's build system need it?

**Answer**: `cmp` is part of GNU `diffutils`. It performs a byte-by-byte comparison of two files. GCC's build system uses `cmp` to verify that generated documentation files (`tm.texi`, `bfd.texi`) match expected outputs as a GFDL license compliance check. If `cmp` is missing, the verification step fails and `make` aborts.

`amazonlinux:2023` minimal install doesn't include `diffutils` by default. The fix is simply adding it to the initial `dnf install` in the Dockerfile:

```dockerfile
RUN dnf install -y gcc gcc-c++ ... diffutils
```

The deeper lesson: Building a compiler from source pulls in unexpected host dependencies. GCC's build documentation lists prerequisites, but not all are obvious until you hit them. A systematic approach is to install `build-essential`-equivalent packages (which usually include diffutils, texinfo, etc.) before attempting compiler builds.

A strong candidate recognizes that `cmp` is from `diffutils`, not coreutils, and understands why GCC needs it. They also know to check GCC's `contrib/download_prerequisites` and the build prerequisites documentation.

---

### Q26: OpenSSL 3.5.7 fails during `conan install --build=missing` with `Can't locate FindBin.pm` in its Configure script. What is the root cause, and what are the trade-offs of different fixes?

**Answer**: OpenSSL's `Configure` script is written in Perl. `FindBin.pm` is a core Perl module that locates the directory of the running Perl script (used for relative path resolution). On Amazon Linux 2023, the base `perl` package doesn't include all core modules — `FindBin` is in a separate subpackage `perl-FindBin`.

Fix: Add `perl-FindBin` to the `dnf install` in the Dockerfile.

Trade-offs of alternative approaches:
- **Install all Perl modules**: `dnf install perl-core` (installs every core module). Pro: no future missing-module surprises. Con: larger image, unnecessary packages.
- **Use `--no-tests` for OpenSSL**: Some builds of OpenSSL skip the Configure script entirely. But `conan install --build=missing` builds from the ConanCenter recipe, which you may not control.
- **Fork OpenSSL Conan recipe**: Add `self.system_requires("perl-FindBin")`. Pro: explicit. Con: another recipe to maintain.

The deeper lesson: Each transitive dependency can pull in unexpected system-level prerequisites. In a Docker build compiling 50+ packages from source, you'll hit 5-10 such "missing system package" issues. The pragmatic approach is to install commonly-needed development packages upfront rather than fixing them one at a time.

---

### Q27: The project uses Conan 2.x for dependency management with `--build=missing`. After fixing OpenSSL, termcap, snappy, and CMake issues, the build progresses to gRPC. gRPC builds with Abseil, Protobuf, and c-ares. What are the three most likely failure modes you'd expect with GCC 16, and how would you prepare for each?

**Answer**:

1. **Abseil + GCC 16 C++23/26 features**: Abseil is Google's foundational library that gRPC depends on heavily. Abseil makes heavy use of C++17/20 features and may have internal assumptions about compiler behavior. GCC 16 changes some C++20 ABI (as noted in Q8). Risk: silent ABI incompatibility between Abseil compiled by GCC 16 and gRPC compiled by the same GCC 16, if Abseil was pre-built. Mitigation: `--build=missing` forces rebuild of everything, which helps.

2. **Protobuf code generation**: `protoc` (the protobuf compiler) may not support the C++26 standard flag. If the Conan recipe or CMake configuration passes `-std=c++26` to `protoc`'s build, it could fail because protoc's C++ codebase isn't tested with C++26. Mitigation: Ensure `CMAKE_CXX_STANDARD` doesn't propagate to `protoc`'s build — some recipes handle this via separate CMake targets.

3. **gRPC's CMake + bundled builds**: gRPC is notorious for CMake configuration complexity. With `ARROW_DEPENDENCY_SOURCE=BUNDLED`, Arrow builds its own copy of gRPC with specific patches and flags. If Arrow's bundled gRPC is incompatible with GCC 16, you'd need to either patch Arrow's ThirdpartyToolchain or use `ARROW_GRPC_USE_SYSTEM=ON` and provide your own gRPC build.

Preparation strategy: Before building, search gRPC and Abseil issue trackers for "GCC 16" or "GCC 15" issues. Pre-read Arrow's `cpp/cmake_modules/ThirdpartyToolchain.cmake` to understand how it configures bundled dependencies. Have fallback flags like `-DCMAKE_CXX_STANDARD=20` ready for deps that can't handle C++26.

---

### Q28: Your Podman/Docker build takes 15+ minutes for a full run, but most of that is GCC 16 compilation (~10 min) followed by dependency compilation. Each fix you make requires a full rebuild. How do you structure the Dockerfile to minimize iteration time when debugging build failures?

**Answer**: Aggressive layer caching with ordered dependencies:

```dockerfile
# Layer 1: System packages (changes rarely — cache forever)
RUN dnf install -y gcc ... diffutils perl-FindBin && dnf clean all

# Layer 2: GCC 16 (changes never — cache forever, ~10 min)
RUN build-gcc-16-from-source

# Layer 3: Python tools (changes rarely)
RUN pip3 install conan cmake ninja

# Layer 4: aws-lambda-cpp (changes rarely)
RUN build-aws-lambda-cpp

# Layer 5: Conan profiles + recipes (changes when you edit recipes)
COPY profiles/ /root/.conan2/profiles/
COPY recipes/ /tmp/recipes/
RUN conan export ...

# Layer 6: Conan install (changes when deps or recipes change — LONG)
COPY conanfile.py .
RUN conan install . --build=missing  # 5-15 min for all deps

# Layer 7: App build (changes frequently — FAST)
COPY src/ src/
RUN conan build .
```

Key rules:
- **Never change earlier layers when fixing later ones**: If snappy fails, the fix goes in the Conan recipe (layer 5-6), not in the GCC build (layer 2).
- **Separate recipe exports from install**: Editing `recipes/arrow/conanfile.py` invalidates layer 5 (fast), but `conan install` (layer 6) still rebuilds from scratch.
- **Use `--no-cache` selectively**: `podman build --no-cache-filter=conan-install` rebuilds only the Conan install layer and everything after.
- **Parallel Docker builds**: For the recommended architecture (separate Arrow/QuantLib/LibTorch stages), each stage can be built independently and cached separately.

A strong candidate understands Docker layer caching semantics and can estimate which layers are "expensive" and structure the Dockerfile to minimize cache invalidation.

---

### Q29: You notice that `profiles/al2023` has these lines under `[settings]`:

```
compiler.version=16
compiler.cppstd=26
    compiler.libcxx=libstdc++11
    build_type=Release
```

Lines 3 and 4 have 4-space indentation. Conan 2.x profiles require settings to be left-aligned. What happens if you don't fix this?

**Answer**: Conan 2.x parses profiles with strict formatting rules. Lines with leading whitespace under `[settings]` are either:
- **Ignored silently**: Conan skips them as comments/whitespace, meaning `compiler.libcxx` and `build_type` fall back to their default values (which may be wrong).
- **Cause a parse error**: Some Conan versions emit a warning or error about unexpected indentation.

If `compiler.libcxx` is silently ignored, Conan defaults to the platform's default libcxx (e.g., `libstdc++11` on Linux, but the compiler version would default to whatever is detected from `CC/CXX` environment variables). If `build_type` is ignored, it defaults to `Release` anyway — but if it defaults to `Debug`, the build produces unstripped binaries with debug symbols.

The fix is trivial (remove leading spaces), but the lesson is: Conan profile formatting bugs are silent killers. Always validate profiles with `conan profile show` after editing.

---

### Q30: Describe the build-debug cycle you experienced in this project. What was the pattern of failures, and what structural change would have prevented the majority of them?

**Answer**: The pattern was a **sequential waterfall of transitive dependency failures**:

```
GCC 16 compiles → OK
termcap (K&R C) → FAIL → fix CFLAGS → rebuild
snappy (CMake too old) → FAIL → install cmake via pip → rebuild
termcap again (K&R hard error) → FAIL → CFLAGS=gnu11 → rebuild
OpenSSL (missing FindBin.pm) → FAIL → install perl-FindBin → rebuild
gRPC? (next expected failure) → ...
```

Each cycle: edit Dockerfile → rebuild (10-15 min) → fail at next dep → repeat.

**Root cause**: GCC 16 is 8 weeks old. The entire Conan dependency tree was built and tested against GCC 11-14. Each transitive dependency has its own build system (CMake, autotools, Makefile), and some of them don't properly handle newer compiler defaults.

**Structural fix**: Build a "dependency smoke test" — a minimal Dockerfile that compiles ALL deps without your application code, in a single fast pass. Use `conan create` or a test recipe that just tries to build every dependency. Run this first, collect ALL failures at once, fix them all, then build the real image. This converts O(N) sequential failures into O(1) batch discovery.

A strong candidate recognizes this as a classic "integration testing" problem — testing all dependencies together catches cross-cutting issues (ABI mismatches, flag incompatibilities) that testing them individually would miss.

---

### Q31: You're told that Arrow S3 needs the AWS C++ SDK (~80-150 MB stripped). Arrow builds the SDK as a bundled dependency. The SDK itself has 10+ `aws-c-*` sub-libraries (aws-c-auth, aws-c-http, aws-c-io, aws-c-s3, etc.), each with its own CMake config, OpenSSL dependency, and threading model. What questions do you ask before accepting this into your static library, and what's your fallback if it causes problems?

**Answer**:

Questions to ask:
1. **Which `aws-c-*` libs does Arrow S3 actually need?** Arrow's ThirdpartyToolchain.cmake limits the SDK to specific services. Can we see the exact list?
2. **Does the bundled AWS SDK conflict with a separately-installed AWS SDK?** If the consumer's application also needs the AWS C++ SDK (e.g., for DynamoDB, SQS), two copies of the SDK in the same binary will cause symbol conflicts.
3. **TLS library choice**: The AWS SDK can use aws-lc (BoringSSL fork), s2n-tls, or OpenSSL. Which does Arrow's bundled build use? Is it the same TLS library the rest of our stack uses?
4. **Static vs shared within the SDK**: Each `aws-c-*` lib is a separate CMake target. Are they all built as static `.a` files? Partial static linking within the SDK can cause ODR violations.

Fallback if problems arise:
1. **`ARROW_S3=OFF` + manual S3 access**: Use the AWS SDK for C++ directly in application code (not via Arrow's S3 filesystem). This gives you control over the SDK version and TLS library.
2. **Arrow IPC + separate S3 download**: Download Parquet/ORC files from S3 using the AWS SDK, then open them locally with Arrow's file reader. Loses Arrow's S3 filesystem pushdown optimizations but is much simpler.
3. **Use Arrow's Python bindings for S3**: If the Lambda function also uses Python, PyArrow's S3 support is more mature than the C++ implementation.

---

### Q32: The project was originally scoped to include PyTorch/LibTorch but was narrowed to Arrow + QuantLib only. What are the specific technical reasons this was the right decision for a first iteration?

**Answer**:

1. **GCC 16 incompatibility**: LibTorch has zero CI testing with GCC 16. GCC 14 already causes ICE (internal compiler error) and linker failures. PyTorch's recommended compiler range is GCC 11-13. Building everything else with GCC 16 and LibTorch with GCC 13 requires a dual-compiler ABI boundary — extremely fragile.

2. **ABI conflicts with Arrow**: LibTorch and Arrow share `variant.h` and `std::shared_ptr` symbol resolution. In a single static binary, these conflicts cause silent ref-count corruption. Workarounds (static-link Arrow, C ABI boundary) add significant complexity.

3. **Size explosion**: Adding LibTorch CPU-only minimal (~30 MB) on top of Arrow Gandiva+LLVM (~500 MB) + Arrow S3+AWS SDK (~80-150 MB) pushes the container image to 2-4 GB, making cold starts 10-15 seconds and CI builds 2-4 hours.

4. **TorchScript deprecation**: PyTorch's own team says TorchScript is unmaintained for 4-5 years. The recommended path (ExecuTorch) is experimental on Linux desktop, unproven on Lambda. Investing in a deprecated tech is wasteful.

5. **Dependency tree complexity**: Arrow + QuantLib already has 50+ transitive dependencies. Adding LibTorch doubles this (it pulls in Abseil, Flatbuffers, FBGEMM, and a custom build of Protobuf that may conflict with Arrow/gRPC's Protobuf).

6. **Build time**: LibTorch from source takes 1-3 hours. Combined with LLVM (30-90 min) and GCC 16 (30-60 min), total CI build time exceeds 4-6 hours — impractical for iterative development.

The right decision was to stabilize Arrow + QuantLib first, establish the Conan/Containerfile patterns, and add PyTorch as a separate phase with a dedicated compiler boundary once the base is solid.

---

## Section 8: Python Extension Architecture (Based on the pybind11 Pivot)

> These questions cover the project's pivot from a standalone C++ executable to a Python extension module loaded by the Lambda Python runtime. A strong candidate should reason about the Python↔C++ boundary, ABI matching, and why "Python does I/O, C++ does compute" is the right separation.

### Q33: The project evolved from a standalone static C++ executable to a pybind11 Python extension loaded by the Lambda Python runtime. What are the architectural advantages of the extension approach, and why is "Python does I/O, C++ does compute" the right separation?

**Answer**:

Architectural advantages of the Python extension approach:

1. **No static-glibc DNS problem**: In the standalone-executable design, a fully-static binary couldn't resolve S3 DNS (glibc 2.34's NSS dlopens `libnss_dns.so`, impossible without a dynamic linker). In the extension design, Python (PyArrow/boto3) does all S3 I/O — the C++ extension has no network code at all. The hardest problem from the previous design simply vanishes.

2. **No AWS SDK in the C++ tree**: Since Python handles S3, the C++ extension doesn't need Arrow S3 → no AWS C++ SDK, no 11 aws-c-* libraries, no OpenSSL pinning. The C++ dep tree shrinks by ~30-40 MB and removes the highest GCC-16 risk areas.

3. **Ecosystem leverage**: Lambda's Python runtime is first-class (RIE, container images, PyArrow, boto3 all battle-tested). The C++ extension plugs into a mature runtime instead of reimplementing the Lambda Runtime API in C++.

4. **Faster iteration**: Python handler changes are instant (no recompile); only C++ compute changes require a rebuild.

The "Python does I/O, C++ does compute" separation is correct because:
- I/O (S3, Parquet reading) is Python's strength — rich libraries, easy credentials, no ABI headaches
- Computation (column math, QuantLib pricing) is C++'s strength — performance, static typing, existing C++ libraries
- The Arrow C Data Interface provides a zero-copy boundary between them — no serialization overhead
- It decouples the two domains: the C++ extension is testable in isolation, deployable unchanged whether data comes from local files or S3

---

### Q34: Your pybind11 extension statically links `libarrow.a`. PyArrow (installed via pip) bundles its own `libarrow.so`. At runtime, both are loaded into the same Python process. Explain the "double-Arrow problem" — what specifically breaks, and how do you avoid it?

**Answer**:

What breaks (the double-Arrow problem):

1. **Symbol clashes**: Both libarrow instances export the same symbols (`arrow::Schema::~Schema()`, etc.). The dynamic linker resolves to whichever was loaded first. If your static libarrow is version 18 and PyArrow's is version 15, calls may hit the wrong implementation.

2. **ODR violations**: The C++ One Definition Rule is violated — two definitions of `arrow::Table`, `arrow::Array`, etc. with potentially different memory layouts. This is undefined behavior.

3. **Vtable/memory-layout mismatch crashes**: Arrow objects carry release callbacks and vtable pointers. If a `arrow::RecordBatch` constructed by your libarrow is destructed by PyArrow's libarrow (or vice versa), the vtable mismatch causes segfaults.

4. **The specific failure mode of the `arrow::py::unwrap_table` shim**: This older approach directly shares `arrow::` objects across the boundary (it extracts the `arrow::Table*` from a `pyarrow.Table`). This is exactly the path that triggers the double-Arrow problem.

How to avoid it — the capsule boundary:

Use the Arrow C Data Interface PyCapsule protocol as the **hard boundary**. Never pass `arrow::` C++ objects across the Python/C++ line — only the frozen C structs (`ArrowSchema`, `ArrowArray`, `ArrowArrayStream`) cross:

- **Input**: PyArrow calls `__arrow_c_array__()` → produces a PyCapsule containing a raw `ArrowArray*` C struct → your C++ calls `arrow::ImportRecordBatch(c_array, c_schema)` which COPIES the data into YOUR libarrow's `arrow::RecordBatch` (living in your address space). The two libarrow instances never interact.
- **Output**: Your C++ builds an `arrow::RecordBatch` (your libarrow) → `arrow::ExportRecordBatch()` serializes it into fresh `ArrowArray`/`ArrowSchema` C structs → wrapped in PyCapsules → PyArrow's `ImportRecordBatch` copies them into ITS libarrow.

The capsule ABI is **frozen** (will never change), so version skew between your static libarrow and PyArrow's libarrow is safe — the C struct layout is stable even if the C++ layouts differ. This is proven in production by Point72/csp.

---

### Q35: Explain the Arrow C Data Interface PyCapsule protocol. What are the exact capsule names, what Python methods implement it, and what's the minimum PyArrow version? Walk through receiving an Arrow table from Python in a pybind11 extension.

**Answer**:

The PyCapsule protocol wraps the frozen Arrow C Data Interface structs in Python `PyCapsule` objects with specific names:

| Python method | Object types | Returns | Capsule name(s) |
|---|---|---|---|
| `__arrow_c_schema__()` | DataType, Field, Schema | 1 capsule | `"arrow_schema"` |
| `__arrow_c_array__(requested_schema=None)` | Array, RecordBatch | tuple of 2 capsules | `("arrow_schema", "arrow_array")` |
| `__arrow_c_stream__(requested_schema=None)` | ChunkedArray, Table, readers | 1 capsule | `"arrow_array_stream"` |

**Minimum version**: PyArrow ≥ 14.0.0 (November 2023, PR #37797). The protocol is stable since; recommend ≥ 15.0.0 for battle-testing.

Receiving an Arrow table in pybind11:

```cpp
#include <arrow/c/abi.h>
#include <arrow/c/bridge.h>
#include <pybind11/pybind11.h>
#include <Python.h>
namespace py = pybind11;

std::shared_ptr<arrow::RecordBatch> import_batch(py::object obj) {
    // 1. Call __arrow_c_array__() → tuple of (schema_capsule, array_capsule)
    py::tuple tup = obj.attr("__arrow_c_array__")().cast<py::tuple>();

    // 2. Extract the C struct pointers (validate capsule names)
    ArrowSchema* cs = reinterpret_cast<ArrowSchema*>(
        PyCapsule_GetPointer(tup[0].ptr(), "arrow_schema"));
    ArrowArray* ca = reinterpret_cast<ArrowArray*>(
        PyCapsule_GetPointer(tup[1].ptr(), "arrow_array"));

    // 3. Import — CONSUMES the structs (calls their release callbacks)
    auto schema = arrow::ImportSchema(cs).ValueOrDie();
    return arrow::ImportRecordBatch(ca, schema).ValueOrDie();
}
```

Critical detail: `ImportRecordBatch` consumes the C structs (invokes `release`). The PyCapsule destructor must guard against double-release by checking `if (c_struct->release != NULL)` before calling it. This is the ownership handoff — once imported, the data lives in your libarrow's address space.

---

### Q36: A pybind11 extension `.so` must dynamically link `libpython3.12.so` but can statically link Arrow, QuantLib, OpenSSL, and libstdc++. Why this asymmetry? What happens if you try to statically link libpython?

**Answer**:

The asymmetry exists because of how CPython loads extension modules:

**Why libpython must be dynamic**: CPython loads a `.so` extension via `dlopen(..., RTLD_LOCAL)` then looks up the `PyInit_<modulename>` symbol. The extension's code calls back into the Python C API (`PyObject*`, `PyArg_ParseTuple`, etc.) — these symbols must resolve to the SAME Python interpreter that loaded the module. If libpython were statically linked into the `.so`, you'd have TWO Python interpreters in the process (the real one + your embedded copy) with separate object allocators, reference counts, and GILs → immediate corruption and crashes. The dynamic link ensures the extension shares the host interpreter's state.

**Why everything else can be static**: Arrow, QuantLib, OpenSSL, zlib, and libstdc++ have no such "single-instance" requirement. Bundling them into the `.so` makes the extension self-contained — no runtime shared-library dependencies beyond libpython + glibc. This is the ideal deployment shape for Lambda: one `.so` file, no `LD_LIBRARY_PATH` games, no version-mismatch risk.

The CMake incantation:
```cmake
pybind11_add_module(my_ext MODULE src/my_ext.cpp)  # MODULE = shared .so
target_link_libraries(my_ext PRIVATE
    Python::Module          # DYNAMIC (required)
    Arrow::arrow_static     # STATIC
    quantlib_static         # STATIC
)
target_link_options(my_ext PRIVATE -static-libgcc -static-libstdc++)  # bundle C++ runtime
```

The `MODULE` keyword (pybind11's default) produces a loadable shared object, distinct from a `SHARED` library (which is for linking, not dlopen) or a `STATIC` archive (which Python cannot load).

---

### Q37: You build the `.so` extension with GCC 16.1 (for C++26). The Lambda Python 3.12 runtime ships GCC 11.2's libstdc++ (max `GLIBCXX_3.4.29`). At runtime: `ImportError: libstdc++.so.6: version 'GLIBCXX_3.4.30' not found`. Diagnose the root cause and give two fixes.

**Answer**:

**Root cause**: GCC 16's libstdc++ introduces new symbol versions (`GLIBCXX_3.4.30`, `GLIBCXX_3.4.31`, ...). When you compile Arrow/QuantLib/your code with GCC 16, the resulting `.so` records dependencies on these new symbol versions in its `.dynsym` table. At runtime, the dynamic linker checks the Lambda runtime's `libstdc++.so.6` (from GCC 11.2, max `GLIBCXX_3.4.29`) and fails because the required version doesn't exist. Verify with: `objdump -T my_ext.so | grep GLIBCXX`.

**Fix 1 (recommended): `-static-libstdc++ -static-libgcc`**. These linker flags bundle the GCC 16 libstdc++ and libgcc code directly into the `.so`. The `.so` no longer references `libstdc++.so.6` at all — `ldd` shows no `libstdc++.so.6` dependency. This is the canonical fix for Lambda native extensions. Caveat: a known TLS-initialization conflict (pytorch#109923) can cause segfaults if another extension (e.g., PyTorch) is imported — doesn't apply here since only Arrow+QuantLib are loaded.

**Fix 2: Bundle the newer `libstdc++.so.6`** into the Lambda image. Copy GCC 16's `libstdc++.so.6` into `/var/task/lib/` (already in `LD_LIBRARY_PATH`) so the runtime finds it. This keeps libstdc++ dynamic (avoids the TLS issue) but requires shipping and version-managing the `.so`. More complex Dockerfile, fragile across runtime updates.

A non-fix worth noting: "just build with GCC 11.2" — rejected because the project requires C++26, which GCC 11 doesn't support. The `-static-libstdc++` approach is the bridge that lets you use GCC 16's language features while running on a GCC 11.2 runtime.

---

### Q38: Why must the Containerfile builder stage be `FROM public.ecr.aws/lambda/python:3.12` rather than `amazonlinux:2023` or `ubuntu:24.04`? What specifically breaks if you build the `.so` on the wrong base?

**Answer**:

The builder must use the exact runtime base to guarantee **CPython ABI matching**. The `.so` extension's filename suffix (`cpython-312-x86_64-linux-gnu.so`) and its internal ABI (struct layouts, calling conventions, `PyInit_` signature) are tied to the exact CPython version and build configuration.

What breaks if you build on the wrong base:

1. **Wrong CPython version/patch**: If you build against CPython 3.12.0 but the Lambda runtime is 3.12.3, internal struct layouts may differ (CPython's internal ABI isn't fully stable across patch releases). The `.so` imports but segfaults on first API call. Building on the runtime base guarantees the exact same `python3.12` binary and `Python.h`.

2. **Wrong glibc version**: If you build on Ubuntu 24.04 (glibc 2.39), the `.so` references `GLIBC_2.39` symbols. The Lambda runtime (AL2023, glibc 2.34) lacks them → `ImportError: /lib64/libc.so.6: version 'GLIBC_2.39' not found`. Building on AL2023-based `lambda/python:3.12` pins glibc to 2.34.

3. **Wrong libstdc++ version**: Same GLIBCXX issue as Q37, but worse — you'd need `-static-libstdc++` AND the glibc would still mismatch.

4. **Wrong SOABI suffix**: CPython computes the extension suffix from its build config. A `.so` built as `cpython-312-x86_64-linux-gnu` on one system might not match what the Lambda Python looks for. Building on the runtime base makes `find_package(Python ... Development.Module)` discover the correct suffix automatically.

The `public.ecr.aws/lambda/python:3.12` image provides: CPython 3.12 at `/var/lang/bin/python3.12`, headers via `dnf install python3.12-devel` (`/var/lang/include/python3.12/Python.h`), `libpython3.12.so` at `/var/lang/lib/`, glibc 2.34, and `dnf`/`microdnf` for installing the build toolchain. The only addition needed: building GCC 16.1 from source (AL2023 ships GCC 11.2 = C++17 only).

---

### Q39: Compare two strategies for the C++ extension: (A) pure C Data Interface with NO libarrow linked, walking `ArrowArray.buffers` directly; vs (B) statically linking libarrow and using `ImportRecordBatch`/`ExportRecordBatch` at the capsule boundary. When would you choose each?

**Answer**:

**Strategy A — pure C structs, no libarrow**:
- The `.so` contains only your compute code + QuantLib (~15-25 MB). You `#include "arrow/c/abi.h"` (a single header, copyable under Apache 2.0) and walk `ArrowArray->children[col_idx]->buffers[1]` as raw `int64_t*`/`double*` pointers.
- Pros: smallest possible binary; no Conan Arrow build (saves 20-40 min build time); zero double-Arrow risk (no libarrow at all); no version coupling to PyArrow.
- Cons: you must manually handle the Arrow memory format — null bitmaps, offsets for variable-length types, dictionaries, nested types (lists/structs). For primitive numeric columns this is trivial; for complex types it's error-prone. No access to Arrow compute kernels, Acero, or Parquet writing in C++.
- Choose when: your computation is purely numeric (sum, mean, QuantLib on doubles), you don't need Arrow's C++ utilities, and binary size / cold start is critical.

**Strategy B — libarrow static + capsule boundary**:
- The `.so` bundles libarrow + QuantLib (~50-80 MB). You receive capsules, call `arrow::ImportRecordBatch` to get a real `arrow::RecordBatch` (your libarrow's address space), use full Arrow C++ API (compute, type inference, casting), then `ExportRecordBatch` to return results.
- Pros: full Arrow C++ capability (compute kernels, Acero, Parquet, IPC, casting); clean typed API; the capsule boundary prevents double-Arrow issues.
- Cons: larger binary; requires the Conan Arrow build; must maintain capsule discipline (never leak `arrow::` objects across the boundary).
- Choose when: you need Arrow's C++ features beyond raw buffer access (compute kernels, complex type handling, Parquet output from C++), and the binary size is acceptable for your Lambda memory/cold-start budget.

The project chose Strategy B because the user wanted Arrow C++ as a library (not just raw buffer access), and the Lambda container limit (10 GB) easily accommodates an 80 MB `.so`. Strategy A is documented as the fallback if size optimization forces it.

---

### Q40: `arrow::ImportRecordBatch` consumes the `ArrowArray` C struct (calls its `release` callback, which frees the producer's buffers). A teammate writes code that manually calls `c_array->release(c_array)` after the import "to be safe." What happens, and how should the PyCapsule destructor be written to prevent this class of bug?

**Answer**:

**What happens — double free / use-after-free**: `ImportRecordBatch` already invoked `release` (which typically frees the underlying buffers and sets `release = NULL`). Calling `release` again either:
- Crashes immediately (the buffers were freed; `release` may now point to invalid memory), or
- Is a no-op IF the import correctly set `c_array->release = NULL` after releasing (glibc's convention), or
- Corrupts the heap if `release` is non-NULL but the memory it frees was already reclaimed.

The bug is subtle because it may appear to work in testing (if the allocator hasn't reused the freed memory) and crash randomly in production.

**Correct PyCapsule destructor** — guard against double-release:
```cpp
static void release_arrow_array_capsule(PyObject* capsule) {
    ArrowArray* array = reinterpret_cast<ArrowArray*>(
        PyCapsule_GetPointer(capsule, "arrow_array"));
    if (array->release != NULL) {   // <-- THE GUARD
        array->release(array);      //    idempotent: sets release=NULL after freeing
    }
    free(array);  // free the struct itself (the C Data Interface spec allows this)
}
```

The key invariant: the Arrow C Data Interface spec requires that after `release(array)` is called, `array->release` MUST be set to `NULL`. So checking `release != NULL` before calling is the correct idempotent guard. The `free(array)` at the end frees the struct allocation (the `ArrowArray` itself was `malloc`'d by the exporter), separate from the buffer memory that `release` freed.

**The broader lesson**: ownership in the C Data Interface is a handoff. Once you call `Import*`, you own the data (in `arrow::` form) and the C struct is spent. Never touch the C struct after import. Document this at every capsule boundary in your code.

---

### Q41: Your project compiles the demo handler at `-std=c++26` but Arrow and QuantLib at `-std=c++17`. Are there ABI risks in linking C++17-compiled libraries into a C++26 executable? What did you have to verify?

**Answer**:

**The good news — ABI-safe within the same GCC major version**: The C++ ABI is determined by the libstdc++ version (which is GCC-version-specific), not by the `-std=` flag. Compiling some translation units with `-std=c++17` and others with `-std=c++26`, all with GCC 16, links cleanly because:
- They all use the SAME libstdc++ (GCC 16's), so `std::string`, `std::vector`, etc. have identical layouts across the TUs.
- The Itanium C++ ABI (name mangling, vtable layout, calling convention) doesn't change between `-std=c++17` and `-std=c++26`.

**The real ABI break is cross-GCC-version, not cross-std**: GCC 16 broke the C++20 *library* ABI vs GCC 15 (std::atomic, std::format, std::ranges internals changed). The critical rule: ALL object files — yours, Arrow's, QuantLib's — must be compiled with GCC 16 (or at least the same major version). You cannot link GCC 15-compiled Arrow with GCC 16-compiled handler code. This is why the project builds GCC 16 from source and compiles the ENTIRE dependency tree with it.

**What to verify**:
1. The Conan profile sets `compiler.version=16` so Conan rebuilds all deps with GCC 16 (`--build=missing`).
2. The `-std=c++26` is set ONLY on the handler TU via `target_compile_features(... cxx_std_26)`, not globally — Arrow/QuantLib stay on their tested `-std=c++17`.
3. No dependency ships pre-built binaries (everything is `--build=missing` from source with GCC 16).
4. `_GLIBCXX_USE_CXX11_ABI` is consistent (1) across all TUs — GCC 16 defaults to the CXX11 ABI; verify no dep forces the old ABI.

A candidate who conflates "C++ standard version" with "ABI version" is weaker. The standard version is a language feature set; the ABI is a binary compatibility contract governed by the compiler/library version.

---

### Q42: You run `strip --strip-all` on the pybind11 `.so` to minimize size. Python then fails: `ImportError: dynamic module does not define module export function (PyInit_sum_columns)`. What happened, and what's the correct strip command?

**Answer**:

**What happened**: `--strip-all` removes the entire symbol table, including the **dynamic** symbol table (`.dynsym`) that the dynamic linker uses to resolve symbols at `dlopen` time. `PyInit_sum_columns` — the entry point CPython looks for when importing the module — lives in `.dynsym`. With it stripped, CPython's import machinery (`_PyObject_CallFunctionObjArgs` on the resolved `PyInit_*` symbol) can't find the entry point and aborts.

A `.so` is fundamentally different from an executable regarding symbols: executables only need their symbols resolved at link time; shared libraries / loadable modules must EXPORT their symbols dynamically for runtime consumers (like CPython's import). Stripping the dynamic symbol table breaks the module contract.

**Correct command: `strip --strip-unneeded`**:
- `--strip-unneeded` removes debug symbols and non-essential local symbols BUT preserves the dynamic symbol table (`.dynsym`) and the dynamic string table. `PyInit_sum_columns` remains exported. Verify after stripping:
  ```bash
  objdump -T sum_columns.so | grep PyInit_sum_columns
  # must show: .dynsym  DF .text  ... PyInit_sum_columns
  ```

**The hierarchy of strip aggressiveness**:
| Command | Removes | Keeps `.dynsym`? | Safe for `.so`? |
|---|---|---|---|
| `strip --strip-debug` | debug info only | Yes | Yes |
| `strip --strip-unneeded` | debug + unneeded locals | Yes | **Yes (recommended)** |
| `strip --strip-all` | everything possible | **No** | **No — breaks imports** |

Bonus: UPX (executable packer) is also unsafe for Python `.so` modules — CPython's `dlopen` rejects packed shared objects. Size optimization for a pybind11 `.so` is limited to `--strip-unneeded` + compiler flags (`-Os`, gc-sections, LTO); binary-level packing doesn't apply.

---

### Q43: Two architects debate where S3 reads should happen. Architect A: "Do it in C++ via Arrow S3 — the extension already links Arrow, so use its S3 filesystem." Architect B: "Do it in Python via PyArrow/boto3 — C++ should be pure compute." Which is right for a Lambda deployment, and why? Give three concrete reasons.

**Answer**:

Architect B is right — Python does S3, C++ stays pure compute. Three concrete reasons:

1. **Eliminates the static-glibc DNS problem entirely.** Arrow S3 in C++ uses the AWS SDK, which calls `getaddrinfo()`, which goes through glibc NSS. In a Lambda Python runtime, this works (glibc is dynamic from the base image) — but it adds the entire AWS C++ SDK (~30-40 MB, 11 aws-c-* libraries) to the C++ dependency tree, all of which are pure C with GCC-16/C23 breakage risk. Python's boto3/PyArrow handle S3 natively with zero C++ build complexity.

2. **Decouples I/O from compute — the extension becomes data-source-agnostic.** If C++ reads S3 directly, the extension is hardwired to S3 (with credentials, endpoint config, retry logic baked into C++). If Python does I/O, the extension receives Arrow data via the C Data Interface regardless of source — local file, S3, in-memory test fixture, or a future Kafka stream. The same `.so` works everywhere. Testing is trivial: Python feeds it local data; no S3 mocking needed in the C++ test path.

3. **Credentials and retry logic are Python's strength.** S3 access on Lambda uses the execution role (IAM), credential rotation, region-aware endpoints, and SDK retry policies. Python's boto3 handles all of this automatically and is battle-tested on Lambda. Reimplementing credential chains and retry logic in C++ (via the AWS SDK) is reinventing a solved problem with a worse debugging experience. When an S3 read fails in production, Python's traceback is actionable; a C++ AWS-SDK error is opaque.

The one case where Architect A wins: if the C++ compute needs to read a SPECIFIC byte range of a huge Parquet file on S3 (Arrow S3 pushdown / column pruning) and streaming the whole file through Python is too slow. But for the typical "read table, compute, write table" flow, the Python-IO / C++-compute split is strictly better. The project's task 005 (S3 round-trip) implements exactly this: Python reads/writes S3, the C++ extension is unchanged from the local-file milestone — proving the clean separation.

---

### Q44: Design the reverse path — your C++ extension computes a result and must return an Arrow table to Python. Walk through the capsule export, including memory ownership and destructor responsibilities.

**Answer**:

The export mirrors the import in reverse. Your C++ builds an `arrow::RecordBatch` (in your libarrow's address space), serializes it into fresh C structs via `ExportRecordBatch`, wraps those structs in PyCapsules with release destructors, and returns them. PyArrow's import consumes the structs.

```cpp
#include <arrow/c/abi.h>
#include <arrow/c/bridge.h>
#include <pybind11/pybind11.h>
#include <cstdlib>
namespace py = pybind11;

// Destructor: called when the PyCapsule is GC'd (if Python didn't consume it)
// OR after PyArrow's ImportRecordBatch has consumed+released the struct.
static void release_schema_capsule(PyObject* cap) {
    ArrowSchema* s = reinterpret_cast<ArrowSchema*>(
        PyCapsule_GetPointer(cap, "arrow_schema"));
    if (s->release != NULL) s->release(s);  // idempotent guard (see Q40)
    free(s);
}
static void release_array_capsule(PyObject* cap) {
    ArrowArray* a = reinterpret_cast<ArrowArray*>(
        PyCapsule_GetPointer(cap, "arrow_array"));
    if (a->release != NULL) a->release(a);
    free(a);
}

py::tuple export_record_batch(std::shared_ptr<arrow::RecordBatch> batch) {
    // 1. Allocate fresh C structs (will be freed by the capsule destructors)
    ArrowSchema* c_schema = static_cast<ArrowSchema*>(malloc(sizeof(ArrowSchema)));
    ArrowArray*  c_array  = static_cast<ArrowArray*>(malloc(sizeof(ArrowArray)));

    // 2. Export — copies/moves data ownership from arrow:: into the C structs
    //    (the arrow::RecordBatch can be destroyed after this; the C struct owns the buffers)
    arrow::Status st = arrow::ExportRecordBatch(*batch, c_array, c_schema);
    if (!st.ok()) { free(c_schema); free(c_array); throw std::runtime_error(st.ToString()); }

    // 3. Wrap each in a PyCapsule with the correct name + destructor
    py::capsule schema_cap(c_schema, "arrow_schema", release_schema_capsule);
    py::capsule array_cap(c_array,  "arrow_array",  release_array_capsule);

    // 4. Return as tuple — PyArrow consumes via __arrow_c_array__ protocol
    return py::make_tuple(schema_cap, array_cap);
}
```

**Memory ownership flow**:
1. `ExportRecordBatch` MOVES buffer ownership from the `arrow::RecordBatch` into the C structs (the `ArrowArray.release` callback now owns freeing them). The original `arrow::RecordBatch` can be destroyed — its destructor won't free the exported buffers.
2. The PyCapsule holds the `ArrowArray*`. If Python's PyArrow calls `__arrow_c_array__` → `ImportRecordBatch`, that import consumes the struct (calls `release`, freeing buffers, sets `release=NULL`). The capsule's destructor then runs at GC time: sees `release==NULL`, skips re-release, just `free(array)`.
3. If Python NEVER consumes the capsule (e.g., it's discarded), the capsule destructor runs: sees `release!=NULL`, calls it (frees buffers), then `free(array)`. No leak.

**Consuming in Python**: The returned tuple can be passed to `pyarrow.record_batch()` or wrapped in an object implementing `__arrow_c_array__`:
```python
import pyarrow as pa
schema_cap, array_cap = ext.compute_and_export(input_table)
# PyArrow reconstructs the RecordBatch from the capsules (zero-copy)
result = pa.RecordBatch.from_arrays(...)  # or a wrapper class
```

The cleanest production pattern (used by Point72/csp): make your extension's return objects implement `__arrow_c_stream__` so they're polymorphically accepted by any Arrow-consuming Python library (PyArrow, Polars, DuckDB, pandas via PyArrow).

---

## Section 9: The Real Build Iteration (10 Actual Fixes Applied)

> These questions are drawn from the ACTUAL build-debugging session that took the pybind11 extension from zero to a passing cleanroom test. Each question corresponds to a real failure encountered and fixed during iterative `podman build` runs. A candidate who has built complex C++ Conan projects with bleeding-edge compilers will recognize these patterns immediately.

### Q45: Your custom Conan recipe for QuantLib calls `self.conan_data["sources"][self.version]` in its `source()` method, but the build fails with `TypeError: 'NoneType' object is not subscriptable`. What is missing?

**Answer**: The recipe expects a `conandata.yml` file in the recipe folder that defines the source download URL for each version. Without it, `self.conan_data` is `None` and the subscript fails. The fix is to create `conandata.yml`:

```yaml
sources:
  "1.38":
    url: https://github.com/lballabio/QuantLib/archive/refs/tags/v1.38.tar.gz
```

In Conan 2.x, `conandata.yml` is the standard way to separate version-specific data (URLs, checksums, patches) from the recipe logic. The `conan export` command copies it alongside `conanfile.py` to the local cache. Without it, any recipe that uses `self.conan_data` crashes at `source()` time.

A common mistake: writing a custom recipe with `source()` that references `conan_data` but forgetting to create the `conandata.yml` file. The recipe looks correct in isolation but fails at build time.

---

### Q46: Your custom Conan recipe's `source()` method works, but `generate()` fails: `Existing CMakePresets.json not generated by Conan cannot be overwritten`. The project's source archive ships its own `CMakePresets.json`. What's the fix?

**Answer**: Conan's `CMakeToolchain.generate()` writes a `CMakePresets.json` to the generators folder. If the generators folder coincides with the source folder (because the recipe uses manual `self.folders.source` / `self.folders.build` without setting `self.folders.generators`), Conan finds the project's existing `CMakePresets.json` and refuses to overwrite it.

Fix: use `cmake_layout(self, src_folder=".")` instead of manual `self.folders` setup. `cmake_layout` correctly separates the source, build, and generators folders, placing generated files in a dedicated subdirectory that doesn't collide with the project's own CMake files.

Alternatively, set `self.folders.generators = "build"` explicitly to redirect Conan's generated files to the build folder.

---

### Q47: You use `--mount=type=cache,target=/root/.conan2` on all Conan RUN steps in your Containerfile for fast iteration. After fixing a recipe and rebuilding, the old (unfixed) recipe is still used — Conan doesn't pick up your changes. Why?

**Answer**: The cache mount persists the Conan local cache across builds, including previously-exported recipe revisions. When you `conan export` the fixed recipe, it creates a NEW revision in the cache. But Conan's dependency resolution may still pick the OLD revision if the new one hasn't fully propagated (the cache's internal index can be stale when the mount is shared across RUN steps with different lifecycles).

Fix: add `conan remove 'arrow/*' --force` BEFORE `conan export` to clear all old revisions of the changed recipe from the cache. This forces Conan to use only the freshly-exported revision. The packages for OTHER dependencies (lz4, zstd, etc.) remain cached and are reused — only the changed recipe rebuilds.

The deeper lesson: `--mount=type=cache` is a double-edged sword. It dramatically speeds up iteration (cached deps skip rebuild) but can serve stale recipe revisions if not explicitly cleared. Always `conan remove` changed recipes before re-exporting when using cache mounts.

---

### Q48: Your Arrow Conan recipe sets `self.folders.source = "cpp"` (Arrow's CMakeLists.txt is in the `cpp/` subdirectory). But CMake fails: `The source directory ".../b/cpp" does not appear to contain CMakeLists.txt`. The actual CMakeLists.txt is at `.../b/cpp/cpp/CMakeLists.txt` (doubled `cpp/`). Explain what happened.

**Answer**: The Apache Arrow release archive extracts to `cpp/CMakeLists.txt` at the top level (after `strip_root=True`). When `self.folders.source = "cpp"`, Conan's `source()` method extracts the archive INTO the `cpp/` subfolder of the source root. The archive's own `cpp/` directory nests inside, creating `cpp/cpp/CMakeLists.txt`.

Then during `build()`, CMake looks for `CMakeLists.txt` at `<source_root>/cpp/` (the `folders.source` offset) but finds an empty directory — the actual file is one level deeper at `cpp/cpp/`.

The fix used in the project: dynamically search for `CMakeLists.txt` at build time and monkey-patch the `source_folder` property to point to the correct location:

```python
def build(self):
    import subprocess, os
    result = subprocess.run(
        ["find", "/root/.conan2/p/b", "-name", "CMakeLists.txt",
         "-path", "*/cpp/CMakeLists.txt", "-not", "-path", "*/test*"],
        capture_output=True, text=True, timeout=10)
    candidates = [l.strip() for l in result.stdout.strip().split("\n") if l.strip()]
    source_dir = os.path.dirname(candidates[0]) if candidates else None
    if source_dir and source_dir != self.source_folder:
        cls = type(self)
        orig = cls.source_folder
        cls.source_folder = property(lambda s: source_dir)
        try:
            cmake = CMake(self)
            cmake.configure()
            cmake.build()
        finally:
            cls.source_folder = orig
    else:
        cmake = CMake(self)
        cmake.configure()
        cmake.build()
```

This is a pragmatic workaround for Conan 2.x's folder resolution behavior with subdirectory source layouts. A candidate who understands Conan's internal directory structure (`p/b/<hash>/s/` for source, `p/b/<hash>/b/` for build) can diagnose this class of issue.

---

### Q49: Your Arrow recipe's `generate()` method accesses `self.dependencies["boost"].cpp_info.rootpath` to build `CMAKE_PREFIX_PATH`. The build fails: `AttributeError: '_Component' object has no attribute 'rootpath'`. Why does this work for some dependencies but not boost?

**Answer**: When boost is configured as `header_only=True` (via the consumer's `override=True`), Conan's `cpp_info` for boost returns a `_Component` object instead of the top-level `CppInfo` object. The `rootpath` attribute exists on `CppInfo` but not on `_Component`.

For non-header-only dependencies (lz4, zstd, thrift, etc.), `cpp_info` returns the full `CppInfo` object which has `rootpath`. The asymmetry only manifests with header-only packages or packages whose `cpp_info` is structured as components.

Fix: use `self.dependencies["boost"].package_folder` instead of `.cpp_info.rootpath`. The `package_folder` attribute is always available on the dependency object regardless of how its `cpp_info` is structured.

The project's fix replaced ALL `.cpp_info.rootpath` accesses in the Arrow recipe with `.package_folder` for robustness.

---

### Q50: Arrow's compute module fails to compile: `re2/re2.h` includes `absl/base/call_once.h` which is not found. re2 depends on abseil, and both are in the Conan graph. Why isn't the transitive include path set up?

**Answer**: The ConanCenter `re2` recipe declares its dependency on abseil, but the generated CMakeDeps config doesn't properly propagate abseil's include directories as transitive. When Arrow's CMake finds `re2::re2` via `find_package(re2)`, the re2 target's `INTERFACE_INCLUDE_DIRECTORIES` only includes re2's own headers — not abseil's. Since `re2/re2.h` directly `#include`s abseil headers, the compiler can't find them.

This is a known weakness in some ConanCenter recipes: the `cpp_info.components["re2"].requires = ["abseil::abseil"]` declaration should make the include transitive via CMake's `target_link_libraries(... INTERFACE)`, but the generated CMake config sometimes doesn't set this up correctly.

Fix: explicitly add abseil's include directory to the C++ compiler flags in Arrow's `generate()`:

```python
if "abseil" in self.dependencies:
    abseil_inc = os.path.join(self.dependencies["abseil"].package_folder, "include")
    cxxflags = tc.cache_variables.get("CMAKE_CXX_FLAGS", "")
    tc.cache_variables["CMAKE_CXX_FLAGS"] = f"{cxxflags} -I{abseil_inc}".strip()
```

This is a blunt instrument (adds the include to ALL compilation units, not just those that include re2.h), but it resolves the transitive include gap reliably.

---

### Q51: You `pip install pybind11` in the builder image, but CMake's `find_package(pybind11 REQUIRED)` fails with "Could not find a package configuration file provided by pybind11". Why doesn't pip-installed pybind11 provide CMake config files?

**Answer**: pip-installed pybind11 DOES provide CMake config files — they're inside the Python site-packages directory (e.g., `/var/lang/lib/python3.12/site-packages/pybind11/share/cmake/pybind11/`). But CMake doesn't know to look there. Unlike Conan-managed dependencies (which CMakeDeps places in the generators folder), pip-installed packages require explicit path configuration.

Three approaches, ranked:

1. **Dynamic detection (used in the project)**: query pybind11's CMake dir via Python at CMake configure time:
```cmake
execute_process(
    COMMAND "${Python_EXECUTABLE}" -c "import pybind11; print(pybind11.get_cmake_dir())"
    OUTPUT_VARIABLE PYBIND11_CMAKE_DIR
    OUTPUT_STRIP_TRAILING_WHITESPACE
)
list(APPEND CMAKE_PREFIX_PATH "${PYBIND11_CMAKE_DIR}")
find_package(pybind11 CONFIG REQUIRED)
```

2. **Conan tool_require**: add `self.tool_requires("pybind11/2.13.x")` — Conan generates the CMakeDeps config. But in practice, the Conan pybind11 recipe's CMakeDeps generation was unreliable in this project (the config wasn't found).

3. **Hardcode the path**: `set(pybind11_DIR /var/lang/lib/python3.12/site-packages/pybind11/share/cmake/pybind11)` — fragile across Python versions.

The dynamic detection (approach 1) is the most robust: it works regardless of the Python installation path and doesn't depend on Conan's CMakeDeps generation.

---

### Q52: Your CMakeLists.txt links `Arrow::arrow_static` but CMake says the target doesn't exist, even though `find_package(Arrow REQUIRED CONFIG)` succeeded. You then try `arrow::arrow_static` (lowercase) — same error. What controls the CMake target name in Conan 2.x?

**Answer**: In Conan 2.x, the CMake target name is controlled by `cpp_info.set_property("cmake_target_name", ...)` in the recipe — NOT by the recipe's `name` attribute or the component name.

The Arrow recipe sets:
```python
arrow = self.cpp_info.components["arrow_static"]
arrow.set_property("cmake_target_name", "Arrow::arrow_static")  # capital A
arrow.set_property("cmake_file_name", "Arrow")
```

So the correct target is `Arrow::arrow_static` (capital A), and `find_package(Arrow REQUIRED CONFIG)` (capital A) finds the config. Neither `arrow::arrow_static` (lowercase, the default) nor a bare `arrow_static` works because the recipe explicitly overrides the target name.

The debugging process: grep the recipe for `set_property.*cmake_target_name` to find the actual target name. Don't assume the default naming convention (`name::component`) — custom recipes frequently override it.

In this project, the initial CMakeLists.txt used `Parquet::parquet_static` which required a separate `find_package(Parquet)` — because the Arrow recipe sets `parquet.set_property("cmake_file_name", "Parquet")`, making Parquet a separate CMake package. The fix was to remove the separate Parquet find_package (parquet isn't needed directly for the sum_columns extension).

---

### Q53: You set `self.requires("boost/1.90.0", options={"header_only": True}, override=True)` to resolve a version conflict. But the build log shows boost compiling ALL its libraries (filesystem, regex, system, etc.) — `header_only=True` didn't take effect. Why?

**Answer**: In Conan 2.x, `override=True` replaces the VERSION of a package across the dependency graph. But the OPTIONS you set on the override only apply to the CONSUMER's direct requirement — they may not propagate to transitive consumers (like the arrow recipe) which may have their own boost options.

The arrow recipe requires boost and sets its own options (e.g., `header_only=False` by default). When Conan resolves the graph, the arrow recipe's options for boost take precedence over the consumer's override options for the same fields.

The result: the consumer's `header_only=True` is ignored because the arrow recipe forces `header_only=False`. Boost compiles all its libraries (~5 min of build time), defeating the intent.

Fix options:
1. **Profile-level option override**: set `boost/*:header_only=True` in the Conan profile's `[options]` section, which has higher priority than recipe-level options.
2. **Accept the full build**: boost's full compilation adds ~5 min but doesn't break anything. If build time is acceptable, leave it.
3. **Patch the arrow recipe**: force `header_only=True` in the arrow recipe's `configure()` method.

The project chose option 2 (accept the full build) because the build time cost was minor compared to the risk of breaking boost-dependent code in Arrow.

---

### Q54: Your C++ extension calls `obj.attr("__arrow_c_array__")()` on a `pyarrow.Table` but gets `AttributeError: 'pyarrow.lib.Table' object has no attribute '__arrow_c_array__'`. Did you implement the protocol wrong?

**Answer**: No — the implementation is correct, but the INPUT type is wrong. The Arrow C Data Interface PyCapsule protocol distinguishes between contiguous and chunked data:

- `__arrow_c_array__()` is implemented by **Array** and **RecordBatch** (single contiguous chunk).
- `__arrow_c_stream__()` is implemented by **ChunkedArray**, **Table**, and **RecordBatchReader** (multiple chunks).

A `pyarrow.Table` is a collection of `ChunkedArray`s — it may have multiple chunks per column. It implements `__arrow_c_stream__`, not `__arrow_c_array__`.

Fix: convert the Table to a RecordBatch before passing to the extension:
```python
table = pq.read_table("data.parquet")
batch = table.to_batches()[0]  # single-batch RecordBatch
result = ext.sum_columns(batch)  # RecordBatch has __arrow_c_array__
```

For production robustness, the C++ extension should handle BOTH protocols:
1. Try `__arrow_c_array__()` first (for Array/RecordBatch).
2. Fall back to `__arrow_c_stream__()` (for Table/ChunkedArray), reading all batches from the stream.

The project's near-term fix was the Python-side conversion (`table.to_batches()[0]`). A future enhancement should add `__arrow_c_stream__` support to the C++ extension for Tables with multiple chunks.

---

## Section 10: Final Architecture Review

> These questions assess understanding of the COMPLETE working system — from GCC 16 compilation through Conan dependency management to the Lambda Python runtime. A candidate who can answer these has the holistic view needed to maintain and extend the project.

### Q55: Explain the Containerfile's cache mount strategy. Why `--mount=type=cache,target=/root/.conan2` on ALL Conan steps, and why are profiles moved to `/tmp/conan-profiles/`?

**Answer**: The cache mount persists the Conan local cache (recipes + built packages) across Containerfile builds. Without it, each build iteration recompiles ALL dependencies from scratch (30+ minutes). With it, only CHANGED recipes rebuild (~2-5 minutes for Arrow alone).

The mount is on ALL Conan steps (remote add, export, install, build) because they share the same cache volume. The export step writes recipe revisions to the cache; the install step reads them and writes built packages; the build step reads both.

Profiles are moved to `/tmp/conan-profiles/` (image layer, not cached) because the cache mount overlays `/root/.conan2/` entirely — if profiles were inside it, they'd be masked by the (possibly empty on first use) cache mount. By keeping profiles in the image layer and passing `-pr:h /tmp/conan-profiles/al2023 -pr:b /tmp/conan-profiles/al2023`, the profiles are always available regardless of cache state.

The `-pr:b` (build profile) is required because Conan looks for a default build profile at `/root/.conan2/profiles/default` — which doesn't exist when the cache mount is in use. Passing both `-pr:h` and `-pr:b` explicitly avoids the "default profile doesn't exist" error.

---

### Q56: Trace the complete data flow from a Parquet file on disk to the printed column sums. Include every boundary crossing, memory ownership transfer, and the specific Arrow/Python/C++ APIs at each step.

**Answer**:

```
data/sample.parquet (disk)
    │
    ▼ pyarrow.parquet.read_table()
pyarrow.Table (Python, PyArrow's libarrow)
    │
    ▼ table.to_batches()[0]
pyarrow.RecordBatch (Python, PyArrow's libarrow)
    │
    ▼ batch.__arrow_c_array__()  [PyCapsule protocol]
(ArrowSchema*, ArrowArray*) in PyCapsules  [frozen C structs, zero-copy]
    │                                           ╔═══════════════════════╗
    ▼ PyCapsule_GetPointer + arrow::ImportRecordBatch  ║ BOUNDARY CROSSING ║
arrow::RecordBatch (C++, OUR libarrow)            ╚═══════════════════════╝
    │  [data ownership transfers from PyArrow's libarrow to OUR libarrow
    │   via the C struct's release callback — the capsule is now "spent"]
    │
    ▼ sum_numeric_column() for each column
    │   (Int64Array / DoubleArray typed access, IsValid check, accumulate)
    │
    ▼ py::dict construction
py::dict {"col_0": 15.0, "col_1": 50.0} (Python)
    │
    ▼ json.dumps() + print()
"Column sums: {'col_0': 15.0, 'col_1': 50.0}"
```

Key boundary: the `__arrow_c_array__()` → `ImportRecordBatch` step. PyArrow serializes its internal Arrow data into the frozen C structs (`ArrowArray` + `ArrowSchema`). The C structs are plain C — no C++ objects, no libarrow symbols. Our C++ extension calls `ImportRecordBatch` which DESERIALIZES the C structs into OUR libarrow's `arrow::RecordBatch`. The two libarrow instances (PyArrow's and ours) never share memory or symbols. The capsule ABI is frozen, so version skew is safe.

---

### Q57: The builder stage uses `FROM public.ecr.aws/lambda/python:3.12` and then builds GCC 16 from source inside it. Why not use a standard GCC 16 base image (e.g., gcc:16) and just install Python 3.12?

**Answer**: Two critical reasons:

1. **CPython ABI match**: The `.so` extension must be compiled against the EXACT CPython 3.12 binary that the Lambda runtime uses — same struct layouts, same `Python.h`, same `libpython3.12.so`. Using the `lambda/python:3.12` base guarantees this. A `gcc:16` image would have a DIFFERENT CPython (Ubuntu's or Debian's), and the resulting `.so` might segfault on import due to internal struct layout differences.

2. **glibc match**: The Lambda runtime uses AL2023's glibc 2.34. The `lambda/python:3.12` image is based on AL2023. Building on a different base (e.g., Ubuntu with glibc 2.39) would produce a `.so` that references `GLIBC_2.39` symbols not available at Lambda runtime. Building on the runtime base pins glibc to 2.34.

Building GCC 16 from source inside the lambda/python:3.12 image gives us C++26 support while maintaining the exact ABI compatibility the Lambda runtime requires. The GCC build (~10 min) is cached as a Docker layer and only runs once.

---

### Q58: The cleanroom test stage has three RUN assertions: import smoke, functional test, and ldd audit. What does each verify, and why is the ldd audit important?

**Answer**:

1. **Import smoke** (`python3.12 -c "import sum_columns; print('import OK')"`): Verifies the `.so` loads in CPython 3.12 without missing symbols, GLIBCXX version errors, or architecture mismatches. If this fails, the extension can't be used at all.

2. **Functional test** (`python3.12 /tmp/cleanroom_test.py`): Loads a local Parquet via PyArrow, converts to RecordBatch, passes to the C++ extension via the C Data Interface, and asserts the column sums are correct (col_0=15.0, col_1=50.0). This validates the COMPLETE data flow: Parquet → PyArrow → capsule → ImportRecordBatch → typed column sum → Python dict → assertion.

3. **ldd audit** (`ldd ${LAMBDA_TASK_ROOT}/sum_columns.so`): Reveals the `.so`'s dynamic library dependencies. In the current architecture, it shows `libstdc++.so.6` + `libpython3.12.so` + glibc components. The audit confirms:
   - No Arrow/AWS-SDK/OpenSSL `.so` files appear (they're statically linked into the `.so`)
   - The `libstdc++.so.6` resolves to the GCC 16 copy we placed in `/lib64/` (not the runtime's older version)
   - No "not found" entries (all dynamic deps are satisfied by the base image + our copies)

The ldd audit is the last line of defense against deployment-time surprises: if a transitive dependency silently introduced a new `.so` dependency, ldd catches it before the Lambda function fails in production.

---

### Q59: QuantLib is in the Conan dependency graph and builds successfully, but the current `.so` doesn't link it (the CMakeLists.txt has a TODO). How would you add QuantLib to the extension, and what would change?

**Answer**:

1. **CMakeLists.txt**: Add the QuantLib CMake target:
```cmake
find_package(QuantLib REQUIRED CONFIG)
target_link_libraries(sum_columns PRIVATE
    ...
    QuantLib::quantlib  # or whatever the recipe's cmake_target_name is
)
```

2. **sum_columns.cpp**: Add a function that exercises QuantLib:
```cpp
m.def("black_scholes", [](double spot, double strike, double vol, double rate, double maturity) -> double {
    // Use QuantLib to price a European call
    // ...
    return npv;
});
```

3. **Test**: Add a QuantLib assertion to the cleanroom test:
```python
result = ext.black_scholes(100.0, 100.0, 0.2, 0.05, 1.0)
assert result > 10.0  # rough BS call price sanity check
```

4. **Size impact**: QuantLib adds ~15-25 MB to the `.so` (after stripping + gc-sections). The extension grows from ~50-80 MB to ~65-105 MB.

5. **Build time**: QuantLib compiles in ~5-10 minutes (972 source files). With the cache mount, this is a one-time cost.

6. **ABI safety**: QuantLib is C++17, compiled with GCC 16 at `-std=c++17` (from the Conan profile). Our handler TU compiles at `-std=c++26`. This is ABI-safe within GCC 16 (see Q41).

The key prerequisite: checking the QuantLib recipe's `cpp_info.set_property("cmake_target_name", ...)` for the correct CMake target name, similar to the Arrow target name discovery in Q52.

---

### Q60: Rate the final architecture against the original requirements. What trade-offs were made, and what would you improve?

**Answer**: A strong answer demonstrates honest assessment:

| Requirement | Status | Notes |
|---|---|---|
| C++26 with GCC 16.1 | ✅ Met | Handler TU at c++26, deps at c++17 |
| Arrow C++ core + Parquet | ✅ Met | Arrow 18.0.0, parquet+compute |
| QuantLib | ⚠️ Built, not linked | In Conan graph, CMakeLists.txt TODO |
| Pybind11 Python extension | ✅ Met | sum_columns.cpython-312-x86_64-linux-gnu.so |
| Zero-copy Arrow boundary | ✅ Met | C Data Interface PyCapsule protocol |
| Lambda Python 3.12 runtime | ✅ Met | FROM lambda/python:3.12, cleanroom test passes |
| GCC 16 from source | ✅ Met | ~10 min cached layer |
| Conan cache for fast iteration | ✅ Met | --mount=type=cache, only changed recipes rebuild |
| Cleanroom test | ✅ Met | Pure lambda/python:3.12, col_0=15.0, col_1=50.0 |

**Trade-offs made**:
1. **libstdc++ bundled (not static-linked)**: `-static-libstdc++` didn't take effect (likely overridden by pybind11 or Conan toolchain). Workaround: copy GCC 16's `libstdc++.so.6` into the image. Less elegant but works.
2. **Arrow source path monkey-patched**: Conan's folder resolution for subdirectory sources (`self.folders.source = "cpp"`) was broken. Pragmatic `find` + property override was needed.
3. **re2/abseil include hacked**: ConanCenter's re2 recipe doesn't propagate abseil includes transitively. Manual `-I` flag injection in the Arrow recipe.
4. **Table → RecordBatch conversion**: The extension handles `__arrow_c_array__` (RecordBatch) but not `__arrow_c_stream__` (Table). Python-side conversion is a temporary fix.

**What to improve**:
1. **Static libstdc++**: debug why `-static-libstdc++` is overridden; use `CMAKE_CXX_STANDARD_LIBRARIES` or direct archive linking to force it.
2. **`__arrow_c_stream__` support**: handle `pyarrow.Table` directly in C++ (read all batches from the stream).
3. **QuantLib integration**: add the QuantLib CMake target + a demo function.
4. **GH Actions CI**: create `.github/workflows/ci.yml` that runs the full build → test pipeline.
5. **Size profiling**: add `MinSizeRel` + LTO + measure the final `.so` size.
6. ** Conan recipe upstreaming**: submit the conandata.yml + cmake_layout + package_folder fixes to ConanCenter to benefit the community.
