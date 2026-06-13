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
