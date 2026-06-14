# Learning Path: C++26 AWS Lambda Python Extension Developer

> **Audience**: CS graduate who knows basic C++ (pointers, classes, STL containers) and Python (functions, modules, pip). No prior experience with QuantLib, Arrow, Conan, or Lambda.
>
> **Goal**: Pass the 60-question technical interview ([`candidate-interview-questions.md`](./candidate-interview-questions.md)) and contribute to the `lambda_cpp26` project.
>
> **Total estimated time**: 8–12 weeks (full-time) or 16–20 weeks (part-time, 20 h/week).
>
> **Prerequisites**: A working C++ compiler (GCC 14+), Python 3.12+, Podman or Docker, and a GitHub account.

---

## Phase 1 — Modern C++ Foundations (Week 1–2)

> **Interview coverage**: Q6 (`--whole-archive`), Q7 (binary size optimization), Q8 (GCC 16 ABI break), Q41 (C++17 vs C++26 ABI), Q42 (`strip` hierarchy).
>
> **Time estimate**: 40–60 hours.

### 1.1 Move Semantics, Smart Pointers, and RAII

These are the **daily bread** of this project. Every Arrow buffer, every QuantLib handle, every pybind11 wrapper uses smart pointers and move semantics.

| Resource | Type | Specific Coverage | Link |
|---|---|---|---|
| **Nicolai Josuttis — *C++ Move Semantics: The Complete Guide*** | Book (leanpub/print) | Definitive reference. Covers value categories, perfect forwarding, `std::move`, move-only types. Read Ch. 1–8. | [josuttis.com/cppstdmove](http://www.josuttis.com/cppstdmove/cppstdmove.html) |
| **Nicolai Josuttis — CppCon 2025 "The Tricky Parts"** | Video course | Move semantics gotchas, SSO, memory management, allocators. Directly relevant to understanding why Arrow objects carry release callbacks. | [cppcon.org/class-2026-tricky-parts](https://cppcon.org/class-2026-tricky-parts/) |
| **`sum_columns.cpp` in this repo** | Source code | See how `ext::make_shared<>` wraps QuantLib handles (lines 194–210). Every QuantLib object in the project is behind a `shared_ptr`. | [`src/sum_columns.cpp:188–214`](../src/sum_columns.cpp#L188-L214) |

**Project-specific exercises**:
- Read the `sum_columns.cpp` extension and identify every place a `shared_ptr` is used. Explain why each is necessary (hint: QuantLib's observer pattern requires heap-allocated objects with stable addresses).
- Write a minimal `std::unique_ptr`-based wrapper around an `ArrowSchema` C struct that calls `release` in its destructor. This is the ownership model used in Q40.

### 1.2 Templates, Concepts, and C++20/26 Features

The project compiles the handler at `-std=c++26` while dependencies stay at C++17 (Q41). You need to understand what changed.

| Resource | Type | Specific Coverage | Link |
|---|---|---|---|
| **Nicolai Josuttis — *C++20: The Complete Guide*** | Book (print/ebook) | Concepts (Ch. 13–15), ranges (Ch. 16–18), modules (Ch. 7–9), coroutines. This is the single best resource. | [josuttis.com/cppstd20](http://www.josuttis.com/cppstd20/cppstd20.html) |
| **Barry Revzin — "Practical Reflection With C++26" (CppCon 2025)** | Talk | C++26 reflection (`std::meta::info`, `^` operator). GCC 16 implements this — the project may use it. | [YouTube](https://www.youtube.com/watch?v=ZX_z6wzEOG0) |
| **cppreference.com — C++26** | Reference | Complete feature table with paper IDs and GCC 16 support status. Bookmark this. | [en.cppreference.com/cpp/26](https://en.cppreference.com/cpp/26) |
| **GCC 16 Changes Page** | Reference | C++20 ABI break vs GCC 15, default `-std=c++20`, `--default-to-c++20` flag. Critical for Q8. | [gcc.gnu.org/gcc-16/changes.html](https://gcc.gnu.org/gcc-16/changes.html) |

**Project-specific exercises**:
- Explain why `target_compile_features(sum_columns PRIVATE cxx_std_26)` in [`CMakeLists.txt:33`](../src/CMakeLists.txt#L33) only affects the handler TU, not Arrow/QuantLib. (Answer: C++ ABI is per-compiler-version, not per `-std=` flag.)
- Read the GCC 16 changes page and list every C++20 component whose ABI changed. Cross-reference with Q8's answer.

### 1.3 Static Linking, `strip`, and Binary Size

Essential for understanding why the project ships a 50–80 MB `.so` and how to make it smaller.

| Resource | Type | Specific Coverage | Link |
|---|---|---|---|
| **`candidate-interview-questions.md` Q7** | This repo | QuantLib size optimization: `MinSizeRel`, `QL_USE_STD_CLASSES=ON`, selective linking, LTO. | [Q7](./candidate-interview-questions.md#q7) |
| **`candidate-interview-questions.md` Q42** | This repo | `strip --strip-unneeded` vs `--strip-all` for `.so` modules. Why `--strip-all` kills `PyInit_`. | [Q42](./candidate-interview-questions.md#q42) |
| **`ldd` manual page + `objdump -T`** | Tool docs | How to audit dynamic dependencies. Used in Q37 and Q58. | `man ldd`, `man objdump` |

---

## Phase 2 — Python C Extensions & pybind11 (Week 2–3)

> **Interview coverage**: Q33–Q44 (entire Section 8), Q36 (dynamic vs static libpython), Q37 (GLIBCXX fix), Q38 (builder base image), Q54 (`__arrow_c_array__` vs `__arrow_c_stream__`).
>
> **Time estimate**: 30–40 hours.

### 2.1 How CPython Loads Extensions

Before touching pybind11, understand the CPython extension contract.

| Resource | Type | Specific Coverage | Link |
|---|---|---|---|
| **Python C-API docs — "Building C and C++ Extensions"** | Docs | The `PyInit_` entry point, `dlopen(RTLD_LOCAL)`, `MODULE` vs `SHARED` vs `STATIC`. | [docs.python.org/3/extending/building](https://docs.python.org/3/extending/building.html) |
| **`candidate-interview-questions.md` Q36** | This repo | Why libpython must be dynamic (two interpreters problem), why everything else can be static. The CMake incantation. | [Q36](./candidate-interview-questions.md#q36) |
| **`candidate-interview-questions.md` Q38** | This repo | Why the builder must be `FROM lambda/python:3.12`, not Ubuntu. CPython ABI matching, glibc pinning. | [Q38](./candidate-interview-questions.md#q38) |

**Key insight**: The `.so` is loaded via `dlopen`. The `PyInit_sum_columns` symbol must be in the **dynamic** symbol table (`.dynsym`). `strip --strip-all` removes it — this is Q42.

### 2.2 pybind11 Core

| Resource | Type | Specific Coverage | Link |
|---|---|---|---|
| **pybind11 documentation — "Building the extension"** | Docs | `PYBIND11_MODULE`, `m.def()`, argument casting, `py::arg()`. | [pybind11.readthedocs.io](https://pybind11.readthedocs.io/en/stable/basics.html) |
| **pybind11 — "Advanced: GIL"** | Docs | `py::call_guard<py::gil_scoped_release>()`, when to release the GIL for compute. | [pybind11.readthedocs.io/en/stable/advanced/misc.html) |
| **`sum_columns.cpp` in this repo** | Source code | The complete working example: capsule extraction (lines 37–64), typed column access (lines 70–105), QuantLib pricing (lines 137–241), PYBIND11_MODULE definition (lines 153–241). | [`src/sum_columns.cpp`](../src/sum_columns.cpp) |

**Project-specific exercises**:
- Trace the data flow in `sum_columns.cpp` from `__arrow_c_array__()` call to `ImportRecordBatch` to typed column access. Draw a memory diagram showing when ownership transfers.
- Modify `sum_columns.cpp` to add `py::call_guard<py::gil_scoped_release>()` on the `sum_columns` function. Explain why this matters for multi-threaded Lambda (Managed Instances, Q16).

### 2.3 PyCapsule Protocol and Arrow C Data Interface

This is the **hardest conceptual topic** in the interview. Spend extra time here.

| Resource | Type | Specific Coverage | Link |
|---|---|---|---|
| **Arrow PyCapsule Interface specification** | Docs | The three protocols (`__arrow_c_schema__`, `__arrow_c_array__`, `__arrow_c_stream__`), capsule names, minimum PyArrow version (≥14.0). | [arrow.apache.org/docs/.../PyCapsuleInterface.html](https://arrow.apache.org/docs/format/CDataInterface/PyCapsuleInterface.html) |
| **`candidate-interview-questions.md` Q34** | This repo | The "double-Arrow problem" — what breaks when two libarrow instances share a process, and how the capsule boundary prevents it. | [Q34](./candidate-interview-questions.md#q34) |
| **`candidate-interview-questions.md` Q35** | This repo | Walkthrough of receiving an Arrow table: capsule extraction → `ImportRecordBatch` → typed access. Complete code. | [Q35](./candidate-interview-questions.md#q35) |
| **`candidate-interview-questions.md` Q40** | This repo | Double-release bug, correct PyCapsule destructor with idempotent `release != NULL` guard. | [Q40](./candidate-interview-questions.md#q40) |
| **`candidate-interview-questions.md` Q44** | This repo | Export path: `ExportRecordBatch` → PyCapsule wrapping → Python consumption. Complete code. | [Q44](./candidate-interview-questions.md#q44) |
| **`candidate-interview-questions.md` Q54** | This repo | Why `Table` uses `__arrow_c_stream__` but `RecordBatch` uses `__arrow_c_array__`. | [Q54](./candidate-interview-questions.md#q54) |
| **Arrow GH PR #37797 — PyCapsule protocol implementation** | GitHub PR | The original commit that added the protocol. Shows the Cython implementation. | [github.com/apache/arrow/commit/bd61239](https://github.com/apache/arrow/commit/bd61239a32c94e37b9510071c0ffacad455798c0) |
| **`candidate-interview-questions.md` Q56** | This repo | Full data flow trace from Parquet on disk to printed column sums. Memorize this. | [Q56](./candidate-interview-questions.md#q56) |

**Project-specific exercises**:
- Read Q34, Q35, Q40, Q44, Q54, and Q56 back-to-back. They form a complete picture of the capsule protocol.
- Implement the export path: write a C++ function that takes an `arrow::RecordBatch`, calls `ExportRecordBatch`, wraps the result in PyCapsules, and returns a tuple. Test it with PyArrow's `pa.record_batch()` constructor.

---

## Phase 3 — Arrow C++ and Conan 2 (Week 3–5)

> **Interview coverage**: Q5 (Arrow module sizes), Q10 (Arrow S3 + AWS SDK), Q12 (Gandiva/LLVM tradeoffs), Q22 (tool_requires propagation), Q23 (custom recipes), Q45–Q53 (real build failures), Q55 (Conan cache strategy).
>
> **Time estimate**: 60–80 hours.

### 3.1 Apache Arrow C++ Architecture

You don't need to read Arrow's full source, but you need to understand its module structure and build flags.

| Resource | Type | Specific Coverage | Link |
|---|---|---|---|
| **Arrow C++ Build Docs** | Docs | CMake flags, dependency source, static build, bundled deps. | [arrow.apache.org/docs/developers/cpp/building.html](https://arrow.apache.org/docs/dev/developers/cpp/building.html) |
| **`candidate-interview-questions.md` Q5** | This repo | Module-by-module size estimates and dependency table. Gandiva = 500MB+ LLVM. Flight = gRPC. S3 = AWS SDK. | [Q5](./candidate-interview-questions.md#q5) |
| **`candidate-interview-questions.md` Q10** | This repo | How Arrow S3 bundles only needed AWS SDK components via `ThirdpartyToolchain.cmake`. | [Q10](./candidate-interview-questions.md#q10) |
| **`initial-research.md` Section 4.2** | This repo | Full transitive dependency tree (~35 unique libraries), estimated total stripped binary. | [initial-research.md](./initial-research.md) |

### 3.2 Conan 2.x Dependency Management

Conan is the project's package manager. The interview tests deep knowledge of its quirks.

| Resource | Type | Specific Coverage | Link |
|---|---|---|---|
| **Conan 2 Documentation — "Creating Packages" tutorial** | Docs | Recipes, `conandata.yml`, `source()`, `build()`, `package()`, `package_info()`. | [docs.conan.io/2/tutorial/creating_packages](https://docs.conan.io/2/tutorial/creating_packages.html) |
| **Conan 2 — "CMake integration"** | Docs | `CMakeDeps`, `CMakeToolchain`, `cmake_layout()`, `cpp_info.set_property("cmake_target_name")`. | [docs.conan.io/2/reference/tools/cmake](https://docs.conan.io/2/reference/tools/cmake.html) |
| **Conan 2 — "Using tools as packages"** | Docs | `tool_requires`, why it doesn't propagate transitively (Q22). | [docs.conan.io/2/tutorial/consuming_packages/use_tools_as_conan_packages.html](https://docs.conan.io/2/tutorial/consuming_packages/use_tools_as_conan_packages.html) |
| **`candidate-interview-questions.md` Q22** | This repo | `tool_requires` propagation limitation — the single most common Conan 2 pitfall. | [Q22](./candidate-interview-questions.md#q22) |
| **`candidate-interview-questions.md` Q23** | This repo | Three reasons ConanCenter's Arrow recipe was insufficient. | [Q23](./candidate-interview-questions.md#q23) |
| **`candidate-interview-questions.md` Q45–Q53** | This repo | Nine real build failures and fixes: missing `conandata.yml` (Q45), CMakePresets collision (Q46), stale cache (Q47), source path nesting (Q48), `cpp_info.rootpath` vs `package_folder` (Q49), transitive include gaps (Q50), pip pybind11 CMake path (Q51), target naming (Q52), option override propagation (Q53). | [Section 9](./candidate-interview-questions.md#section-9-the-real-build-iteration-10-actual-fixes-applied) |
| **`conanfile.py` in this repo** | Source code | The consumer recipe: Arrow 18.0.0, QuantLib 1.38, boost override, compression codecs. | [`conanfile.py`](../conanfile.py) |

**Project-specific exercises**:
- Read Q45–Q53 sequentially. Each is a real bug encountered during the project build. For each, explain the root cause and fix in your own words.
- Look at the custom Arrow recipe in `recipes/arrow/conanfile.py`. Identify the three specific problems from Q23 that necessitated it.
- Explain why `conan remove 'arrow/*' --force` is needed before `conan export` when using `--mount=type=cache` (Q47).

### 3.3 The Arrow C Data Interface (Deep Dive)

Beyond the PyCapsule protocol, understand the C ABI structs themselves.

| Resource | Type | Specific Coverage | Link |
|---|---|---|---|
| **Arrow C Data Interface specification** | Docs | `ArrowSchema`, `ArrowArray`, `ArrowArrayStream` struct definitions, the `release` callback contract, buffer layout. | [arrow.apache.org/docs/format/CDataInterface.html](https://arrow.apache.org/docs/format/CDataInterface.html) |
| **`arrow/c/abi.h`** | Header file (in Arrow source) | The actual struct definitions. Single header, can be copied independently. | [github.com/apache/arrow/blob/main/cpp/src/arrow/c/abi.h](https://github.com/apache/arrow/blob/main/cpp/src/arrow/c/abi.h) |
| **`candidate-interview-questions.md` Q39** | This repo | Strategy A (pure C structs, no libarrow) vs Strategy B (libarrow + capsule boundary). Trade-offs. | [Q39](./candidate-interview-questions.md#q39) |

---

## Phase 4 — AWS Lambda & Container Build Systems (Week 4–6)

> **Interview coverage**: Q1–Q4 (Lambda fundamentals), Q9 (Docker build pipeline), Q11 (multi-arch), Q15–Q17 (debugging & cold starts), Q24 (aws-lambda-cpp integration), Q25 (GCC build deps), Q28 (Docker layer caching), Q57 (builder base choice), Q58 (cleanroom test).
>
> **Time estimate**: 50–70 hours.

### 4.1 AWS Lambda Container Fundamentals

| Resource | Type | Specific Coverage | Link |
|---|---|---|---|
| **AWS Lambda Docs — "Working with container images"** | Docs | Base images, `provided.al2023`, RIE, image limits (10 GB), cold start. | [docs.aws.amazon.com/lambda/latest/dg/images-create.html](https://docs.aws.amazon.com/lambda/latest/dg/images-create.html) |
| **AWS Lambda Docs — "OS-only runtimes"** | Docs | `provided.al2023` vs `provided.al2` table, deprecation dates, glibc versions. | [docs.aws.amazon.com/lambda/latest/dg/runtimes-provided.html](https://docs.aws.amazon.com/lambda/latest/dg/runtimes-provided.html) |
| **"How Lambda starts containers 15x faster" (Marc Brooker paper summary)** | Blog post | Block-level dedup, tiered caching, manifest structure, why images >30 MB are faster than ZIP. | [dev.to/aws-heroes](https://dev.to/aws-heroes/how-lambda-starts-containers-15x-faster-deep-dive-5077) |
| **"On-demand Container Loading in AWS Lambda" (original paper)** | Academic paper | The full technical paper. Read Sections 1–3 for the architecture; skim the erasure coding details. | [ar5iv.labs.arxiv.org/html/2305.13162](https://ar5iv.labs.arxiv.org/html/2305.13162) |
| **aws-lambda-runtime-interface-emulator (GitHub)** | GitHub repo | RIE architecture, local testing patterns, port 8080, invocation endpoint. | [github.com/aws/aws-lambda-runtime-interface-emulator](https://github.com/aws/aws-lambda-runtime-interface-emulator) |

**Project-specific exercises**:
- Explain why container images (10 GB limit) are required instead of ZIP (250 MB limit) for this project (Q1).
- Draw the Docker multi-stage build architecture from `initial-research.md` Section 6: GCC 16 → Arrow + QuantLib → static library → Lambda runtime.
- Calculate: if the image is 2 GB with Gandiva+LLVM, and Lambda's manifest limit is 25,400 bytes, how many layers can you have? (Each layer entry is ~100 bytes in the manifest.)

### 4.2 Docker/Podman Multi-Stage Builds

| Resource | Type | Specific Coverage | Link |
|---|---|---|---|
| **Docker Docs — "Multi-stage build for C++"** | Docs | The canonical pattern: build stage (full toolchain) → runtime stage (binary only). | [docs.docker.com/guides/cpp/multistage](https://docs.docker.com/guides/cpp/multistage/) |
| **`Containerfile` in this repo** | Source code | The real production build: GCC 16 from source, Conan cache mounts, profile management, cleanroom test stage. | [`Containerfile`](../Containerfile) |
| **`candidate-interview-questions.md` Q28** | This repo | Docker layer caching strategy: ordered dependencies, `--no-cache-filter`, separate recipe exports from install. | [Q28](./candidate-interview-questions.md#q28) |
| **`candidate-interview-questions.md` Q55** | This repo | Conan `--mount=type=cache` strategy, why profiles go in `/tmp/` not inside the cache mount. | [Q55](./candidate-interview-questions.md#q55) |

**Project-specific exercises**:
- Read the `Containerfile` line by line. Explain why each `RUN` command is at its specific position (layer ordering). What would invalidate the cache if you moved `COPY src/` above `conan install`?
- Explain the `--mount=type=cache,target=/root/.conan2` on three separate `RUN` steps. Why is it on all three, not just `conan install`?

### 4.3 glibc, ABI, and Cross-Version Debugging

This is the most important operational skill for the project.

| Resource | Type | Specific Coverage | Link |
|---|---|---|---|
| **`candidate-interview-questions.md` Q15** | This repo | `GLIBC_2.35 not found`: diagnosis with `ldd`, `objdump -T`, `readelf -d`; fix by building on AL2023. | [Q15](./candidate-interview-questions.md#q15) |
| **`candidate-interview-questions.md` Q37** | This repo | `GLIBCXX_3.4.30 not found`: `-static-libstdc++` fix, `objdump -T` verification. | [Q37](./candidate-interview-questions.md#q37) |
| **`candidate-interview-questions.md` Q25** | This repo | `cmp: command not found` during GCC build — `diffutils` dependency. | [Q25](./candidate-interview-questions.md#q25) |
| **`candidate-interview-questions.md` Q26** | This repo | OpenSSL `FindBin.pm` — Perl module packaging on AL2023. | [Q26](./candidate-interview-questions.md#q26) |

**Project-specific exercises**:
- Given a binary that fails with `version 'GLIBC_2.38' not found`, walk through the exact diagnosis steps: `objdump -T binary \| grep GLIBC`, check `readelf -d binary \| grep NEEDED`, identify which Docker image was used.
- Explain the AL2023 libstdc++ versioning bug from April 2025 (mentioned in `initial-research.md`). Why does pinning the image version fix it?

---

## Phase 5 — QuantLib & Financial Computing (Week 5–7)

> **Interview coverage**: Q5 (QuantLib build flags), Q7 (QuantLib size optimization), Q14 (Boost conflicts), Q59 (adding QuantLib to the extension).
>
> **Time estimate**: 30–40 hours.

### 5.1 Financial Mathematics Prerequisites

Before touching QuantLib, you need the math.

| Resource | Type | Specific Coverage | Link |
|---|---|---|---|
| **John C. Hull — *Options, Futures, and Other Derivatives* (11th ed.)** | Textbook | Ch. 1–4 (futures, forwards), Ch. 13–15 (Black-Scholes, Greeks), Ch. 17–18 (volatility, log returns). The gold standard. | [Pearson](https://www.pearson.com/en-gb/subject-catalog/p/options-futures-and-other-derivatives-global-edition/P200000004519) |
| **`sum_columns.cpp` — `historical_volatility()` function** | Source code (this repo) | Log returns, mean, standard deviation, annualization (×√252). 10 lines of C++ that implement the math. | [`src/sum_columns.cpp:137–147`](../src/sum_columns.cpp#L137-L147) |

**Minimum math to know before touching QuantLib**:
- **Log returns**: `r_i = ln(P_{i+1} / P_i)`. Why log, not simple? (Time-additive, symmetric for gains/losses.)
- **Historical volatility**: `σ = std(log_returns) × √252` (annualized from daily).
- **Black-Scholes formula**: `C = S·N(d1) - K·e^{-rT}·N(d2)`. Know what each variable means.
- **Greeks**: delta (Δ), gamma (Γ), theta (Θ), vega (ν), rho (ρ). First-order sensitivities.
- **Put-call parity**: `C - P = S - K·e^{-rT}`.
- **Day count conventions**: `Actual365Fixed`, `Actual360`, `30/360`. Why they matter for interest accrual.

### 5.2 QuantLib C++ API

| Resource | Type | Specific Coverage | Link |
|---|---|---|---|
| **Luigi Ballabio — "Implementing QuantLib" blog — Black-Scholes** | Blog post | QuantLib's `BlackScholesMertonProcess`, `AnalyticEuropeanEngine`, `VanillaOption`, `PlainVanillaPayoff`. Written by the QuantLib maintainer. | [implementingquantlib.com](https://www.implementingquantlib.com/2023/11/black-scholes.html) |
| **QuantLib — EquityOption example** | Source code (GitHub) | The canonical example: European, Bermudan, American options with multiple engines. | [github.com/lballabio/QuantLib/blob/master/Examples/EquityOption/EquityOption.cpp](https://github.com/lballabio/QuantLib/blob/master/Examples/EquityOption/EquityOption.cpp) |
| **QuantLib Guide — "Instruments and pricing engines"** | Notebook | The observer pattern, `SimpleQuote` for mutable market data, switching engines. | [quantlibguide.com](https://www.quantlibguide.com/Instruments%20and%20pricing%20engines.html) |
| **`sum_columns.cpp` — `price_options()` function** | Source code (this repo) | The complete working example in this project: BS process setup, engine, call + put pricing, Greeks extraction. | [`src/sum_columns.cpp:176–241`](../src/sum_columns.cpp#L176-L241) |
| **`candidate-interview-questions.md` Q7** | This repo | QuantLib build flags for size optimization: `QL_USE_STD_CLASSES=ON`, selective linking, LTO. | [Q7](./candidate-interview-questions.md#q7) |
| **`candidate-interview-questions.md` Q59** | This repo | How to add QuantLib to the extension's CMakeLists.txt and expose a `black_scholes()` function. | [Q59](./candidate-interview-questions.md#q59) |

**Project-specific exercises**:
- Read `price_options()` in `sum_columns.cpp`. Map each QuantLib class to the Black-Scholes formula: which class is S? Which is K? Which is σ?
- Explain why QuantLib uses the observer pattern (handles, quotes, term structures) instead of plain doubles. (Answer: market data changes propagate automatically; the same option object can re-price with new data.)
- Build QuantLib from source locally with `QL_USE_STD_CLASSES=ON`. Measure the `libQuantLib.a` size before and after `strip --strip-unneeded`.

---

## Phase 6 — Integration & Interview Preparation (Week 7–8)

> **Interview coverage**: Q4 (RIE local testing), Q9 (CI pipeline), Q16 (cold start optimization), Q17 (GitHub Actions), Q19 (confidence ratings), Q20 (pushback questions), Q30 (build-debug pattern), Q31 (AWS SDK questions), Q32 (scope decisions), Q43 (I/O separation), Q60 (architecture trade-offs).
>
> **Time estimate**: 30–40 hours.

### 6.1 Putting It All Together

At this point you've studied all the individual pieces. Now connect them.

| Resource | Type | Specific Coverage | Link |
|---|---|---|---|
| **`candidate-interview-questions.md` Q56** | This repo | The single most important question: trace the complete data flow from Parquet on disk to printed column sums. | [Q56](./candidate-interview-questions.md#q56) |
| **`candidate-interview-questions.md` Q33** | This repo | The architectural justification for "Python does I/O, C++ does compute." Three concrete reasons. | [Q33](./candidate-interview-questions.md#q33) |
| **`candidate-interview-questions.md` Q43** | This repo | Why S3 reads belong in Python, not C++. The DNS problem, decoupling, credentials. | [Q43](./candidate-interview-questions.md#q43) |
| **`candidate-interview-questions.md` Q60** | This repo | Honest architecture assessment: what was built, what trade-offs were made, what to improve. | [Q60](./candidate-interview-questions.md#q60) |

**Integration exercises**:
- **Build the project from scratch**: Follow the `Containerfile`. Run `podman build`. Fix any issues. Run the cleanroom test. This is the single best preparation.
- **Write Q56 from memory**: Close all references and trace the data flow. Compare with the answer. If you missed a boundary crossing, re-study that phase.
- **Mock interview**: Have someone ask you Q1, Q8, Q34, Q37, Q56, and Q60. These six questions span the entire project.

### 6.2 GitHub Actions and CI

| Resource | Type | Specific Coverage | Link |
|---|---|---|---|
| **`candidate-interview-questions.md` Q17** | This repo | Full CI pipeline: separate deps/lib jobs, matrix for arch, Docker layer caching, ECR publish. | [Q17](./candidate-interview-questions.md#q17) |
| **`candidate-interview-questions.md` Q9** | This repo | Layered Docker build strategy for CI: cache GCC 16, cache LLVM, separate Arrow/QuantLib stages. | [Q9](./candidate-interview-questions.md#q9) |

### 6.3 Interview Strategy

**Questions to study by difficulty tier**:

| Tier | Questions | Why |
|---|---|---|
| **Must nail (automatic fail if wrong)** | Q34 (double-Arrow), Q37 (GLIBCXX), Q38 (builder base), Q56 (data flow), Q8 (GCC 16 ABI) | Core architectural decisions |
| **Strong signal** | Q5 (module sizes), Q7 (size optimization), Q15 (glibc), Q28 (layer caching), Q33 (I/O separation), Q43 (S3 in Python) | Demonstrates operational experience |
| **Differentiator** | Q22 (Conan tool_requires), Q23 (custom recipes), Q39 (Strategy A vs B), Q41 (C++17/26 ABI), Q47 (cache stale), Q50 (transitive includes) | Deep Conan/Arrow knowledge |
| **Leadership signal** | Q12 (Gandiva pushback), Q20 (requirements questions), Q32 (scope decisions), Q60 (trade-off assessment) | Architecture judgment |

**Read these answers last (they synthesize everything)**:
- **Q30** — the build-debug waterfall pattern. Understanding this proves you've lived through real builds.
- **Q20** — the pushback questions. A strong candidate asks these before starting.
- **Q19** — confidence ratings with reasoning. Shows calibrated judgment.

---

## Resource Summary by Phase

### Books
| Book | Author | Phases | Priority |
|---|---|---|---|
| *C++20: The Complete Guide* | Nicolai Josuttis | 1 | **Required** |
| *C++ Move Semantics: The Complete Guide* | Nicolai Josuttis | 1 | **Required** |
| *Options, Futures, and Other Derivatives* (11th ed.) | John C. Hull | 5 | **Required** (Ch. 13–15, 17–18) |

### Talks and Courses
| Talk/Course | Speaker/Platform | Phases | Link |
|---|---|---|---|
| "Practical Reflection With C++26" | Barry Revzin, CppCon 2025 | 1 | [YouTube](https://www.youtube.com/watch?v=ZX_z6wzEOG0) |
| "The Tricky Parts" (Advanced C++) | Nicolai Josuttis, CppCon Academy | 1 | [cppcon.org](https://cppcon.org/class-2026-tricky-parts/) |
| "Function and Class Design with C++2x" | Jeff Garland, CppCon Academy | 1 | [cppcon.org](https://cppcon.org/class-2026-function-class-design/) |

### Documentation (Bookmark These)
| Docs | URL | Phases |
|---|---|---|
| cppreference C++26 | [en.cppreference.com/cpp/26](https://en.cppreference.com/cpp/26) | 1 |
| GCC 16 Changes | [gcc.gnu.org/gcc-16/changes.html](https://gcc.gnu.org/gcc-16/changes.html) | 1, 4 |
| pybind11 docs | [pybind11.readthedocs.io](https://pybind11.readthedocs.io/en/stable/) | 2 |
| Arrow PyCapsule Interface | [arrow.apache.org/.../PyCapsuleInterface.html](https://arrow.apache.org/docs/format/CDataInterface/PyCapsuleInterface.html) | 2, 3 |
| Arrow C Data Interface | [arrow.apache.org/.../CDataInterface.html](https://arrow.apache.org/docs/format/CDataInterface.html) | 2, 3 |
| Arrow C++ Build Docs | [arrow.apache.org/.../cpp/building.html](https://arrow.apache.org/docs/dev/developers/cpp/building.html) | 3 |
| Conan 2 Docs | [docs.conan.io/2](https://docs.conan.io/2/) | 3 |
| AWS Lambda Container Images | [docs.aws.amazon.com/lambda/.../images-create.html](https://docs.aws.amazon.com/lambda/latest/dg/images-create.html) | 4 |
| AWS Lambda RIE | [github.com/aws/aws-lambda-runtime-interface-emulator](https://github.com/aws/aws-lambda-runtime-interface-emulator) | 4 |
| Container Loading Paper | [ar5iv.labs.arxiv.org/html/2305.13162](https://ar5iv.labs.arxiv.org/html/2305.13162) | 4 |
| Docker Multi-Stage Builds | [docs.docker.com/guides/cpp/multistage](https://docs.docker.com/guides/cpp/multistage/) | 4 |
| Implementing QuantLib (blog) | [implementingquantlib.com](https://www.implementingquantlib.com/) | 5 |
| QuantLib Guide | [quantlibguide.com](https://www.quantlibguide.com/) | 5 |

### This Repo (Study These Files)
| File | What to study |
|---|---|
| [`candidate-interview-questions.md`](./candidate-interview-questions.md) | All 60 Q&As — this IS the exam |
| [`initial-research.md`](./initial-research.md) | Module sizes, dependency tree, GCC 16 features, risk matrix |
| [`src/sum_columns.cpp`](../src/sum_columns.cpp) | The complete working extension — read it, modify it, extend it |
| [`src/CMakeLists.txt`](../src/CMakeLists.txt) | CMake target structure, `cxx_std_26`, static linking flags |
| [`conanfile.py`](../conanfile.py) | Consumer recipe, boost override, Arrow options |
| [`Containerfile`](../Containerfile) | Multi-stage build, GCC 16 from source, Conan cache mounts, cleanroom test |
| [`recipes/arrow/conanfile.py`](../recipes/arrow/conanfile.py) | Custom Arrow recipe — understand every deviation from ConanCenter |
| [`recipes/quantlib/conanfile.py`](../recipes/quantlib/conanfile.py) | Custom QuantLib recipe — understand `conandata.yml` dependency |

---

## Weekly Schedule (Full-Time)

```
Week 1  │ Phase 1.1–1.2: Move semantics, smart pointers, C++20/26 features
Week 2  │ Phase 1.3 + Phase 2.1–2.2: Static linking, pybind11 core, GIL
Week 3  │ Phase 2.3 + Phase 3.1: PyCapsule protocol (deep study), Arrow architecture
Week 4  │ Phase 3.2: Conan 2 (recipes, build failures Q45–Q53)
Week 5  │ Phase 4.1–4.2: Lambda fundamentals, Docker builds, glibc/ABI
Week 6  │ Phase 5.1–5.2: Financial math, QuantLib C++ API, integrate into extension
Week 7  │ Phase 6.1: Build the project end-to-end, data flow trace, mock interviews
Week 8  │ Phase 6.2–6.3: CI pipeline, interview strategy, final review of all 60 Q&As
```

## Weekly Schedule (Part-Time, 20 h/week)

```
Weeks  1–2  │ Phase 1 (Modern C++)
Weeks  3–4  │ Phase 2 (pybind11 + PyCapsule)
Weeks  5–7  │ Phase 3 (Arrow + Conan)
Weeks  8–10 │ Phase 4 (Lambda + Docker)
Weeks 11–13 │ Phase 5 (QuantLib)
Weeks 14–16 │ Phase 6 (Integration + Interview prep)
```

---

## Anti-Patterns: What NOT to Do

| ❌ Don't | ✅ Do instead |
|---|---|
| Read generic C++ tutorials that cover what you already know | Jump straight to Josuttis's C++20 book — it's for experienced C++ devs |
| Try to learn Arrow's full C++ API | Focus on the C Data Interface structs and `ImportRecordBatch`/`ExportRecordBatch` only |
| Install Conan 1.x because tutorials are easier | Learn Conan 2.x directly — the project uses 2.x and they're fundamentally different |
| Build a "hello world" Lambda with the ZIP approach | Start with container images — that's what the project uses |
| Read Hull's textbook cover-to-cover | Read Ch. 13–15, 17–18 only (Black-Scholes, Greeks, volatility) |
| Memorize all 60 answers verbatim | Understand the *reasoning* — the interview tests understanding, not recall |
| Skip the build-debug questions (Q21–Q30) | Study them hardest — they test real-world experience, not book knowledge |
