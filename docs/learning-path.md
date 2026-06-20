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

## Phase 7 — DevContainer Operations & Tooling Case Studies (Week 8)

> **Audience expansion**: This phase covers operational patterns every contributor hits when joining the project — Podman setup, prebuilt image workflow, IDE configuration, mixed-language debugging. Pair with [`developer-guide.md`](./developer-guide.md).
>
> **Time estimate**: 10–15 hours (read + reproduce each case study).

### 7.1 Podman + WSL2 DevContainer Setup

The project's devcontainer runs under Podman (not Docker) on WSL2. Canonical
setup is automated by [`setup-podman-wsl.sh`](../setup-podman-wsl.sh).

| Resource | Type | Specific Coverage | Link |
|---|---|---|---|
| **`setup-podman-wsl.sh`** | Script (this repo) | Ubuntu rootful Podman + systemd enable + VSCode Machine settings. Idempotent. | [`setup-podman-wsl.sh`](../setup-podman-wsl.sh) |
| **Conan 2.x CLI gotchas** | Internal notes | `-f` is `--format`, not `--force`. `conan remove` doesn't prompt. `conan export` creates new recipe revision. | (this phase) |
| **WSL2 .wslconfig** | Config reference | GCC 16 source compile needs ~12 GB RAM. Default WSL2 caps at 50% of host RAM. | (this phase) |

**Case study — Podman path differs from Docker**:
The devcontainer.json's `remoteUser: "root"` works with rootful Podman (container
root maps to host root, no permission issues on bind mounts). Under rootless
Podman, the same config produces permission errors because container root maps
to a non-root host UID. The setup script detects and warns about this.

**Exercise**: Read `setup-podman-wsl.sh`. Explain why it writes to TWO
`settings.json` locations — `~/.vscode-server/data/Machine/settings.json`
(WSL-side Machine scope) AND workspace `.vscode/settings.json`.

### 7.2 Conan 2.x CMakeDeps Multi-Component Bug (Real Case Study)

This is the kind of build-system bug that distinguishes "ran the tutorial"
from "shipped a project". Read it in full.

**Symptom**: Consumer's `find_package(Arrow REQUIRED CONFIG)` fails with:
```
CMake Error: Library 'parquet' not found in package.
Call Stack: Arrow-Target-release.cmake:23 (conan_package_library_targets)
```

**Root cause**: The custom arrow recipe at `recipes/arrow/conanfile.py` set
`cmake_file_name` PER-COMPONENT with different values (Arrow vs Parquet vs
ArrowFlight). This caused Conan's CMakeDeps to emit `parquet` library
resolution in `Arrow-Target-release.cmake` where it couldn't be found.

**Fix**: Align with [ConanCenter's canonical arrow recipe](https://github.com/conan-io/conan-center-index/blob/master/recipes/arrow/all/conanfile.py):

```python
# ONE top-level cmake_file_name (NOT per-component)
self.cpp_info.set_property("cmake_file_name", "Arrow")

# Components set cmake_target_name only — all share Arrow's config file
self.cpp_info.components["libarrow"].set_property(
    "cmake_target_name", "Arrow::arrow_static")
self.cpp_info.components["libparquet"].set_property(
    "cmake_target_name", "Parquet::parquet_static")
```

Plus `rmdir(lib/cmake)` after `cmake.install()` so upstream ArrowConfig.cmake
doesn't shadow Conan's CMakeDeps-generated one.

| Resource | Type | Specific Coverage | Link |
|---|---|---|---|
| **ConanCenter arrow recipe** | Reference impl | The canonical multi-component pattern | [conan-io/conan-center-index/.../arrow](https://github.com/conan-io/conan-center-index/blob/master/recipes/arrow/all/conanfile.py) |
| **Conan 2 — cpp_info properties** | Docs | `cmake_file_name` vs `cmake_target_name` semantics | [docs.conan.io/2/reference/conanfile/attributes.html](https://docs.conan.io/2/reference/conanfile/attributes.html) |
| **`recipes/arrow/conanfile.py`** | Source (this repo) | The fixed recipe — single top-level `cmake_file_name`, six components with `cmake_target_name` only | [`recipes/arrow/conanfile.py`](../recipes/arrow/conanfile.py) |
| **Commit `87d1c94`** | Git history | The fix commit with full reasoning in message | `git show 87d1c94` |

**Exercise**: Read both the broken (pre-87d1c94) and fixed recipe. For each
component (arrow_static, parquet_static, arrow_flight_static, gandiva_static,
arrow_bundled_dependencies), explain what would happen if you removed the
top-level `cmake_file_name` and kept only per-component values.

### 7.3 Prebuilt DevContainer Image Workflow

The devcontainer takes 30+ minutes to build from scratch (GCC 16 source
compile dominates). Teammates can't afford this on every clone.

**Solution**: publish a prebuilt image to ghcr.io. devcontainer.json uses
`"image":` for fast pull (2–5 min), keeps `"build":` for explicit rebuilds.
`postCreateCommand` is removed because deps are baked into the image.

| Resource | Type | Specific Coverage | Link |
|---|---|---|---|
| **`scripts/build-devcontainer.sh`** | Script (this repo) | Rebuild from Dockerfile + bake Conan cache + commit + push | [`scripts/build-devcontainer.sh`](../scripts/build-devcontainer.sh) |
| **`scripts/push-devcontainer.sh`** | Script (this repo) | Commit CURRENTLY RUNNING container + push (fast path for known-good state) | [`scripts/push-devcontainer.sh`](../scripts/push-devcontainer.sh) |
| **`scripts/save-devcontainer-tarball.sh`** | Script (this repo) | Export to .tar.gz + sha256 for airgapped distribution | [`scripts/save-devcontainer-tarball.sh`](../scripts/save-devcontainer-tarball.sh) |
| **`.github/workflows/devcontainer.yml`** | CI workflow | Auto-rebuild on `.devcontainer/`, `recipes/`, `src/`, `conanfile.py` changes + weekly cron | [`.github/workflows/devcontainer.yml`](../.github/workflows/devcontainer.yml) |

**Case study — Lambda ENTRYPOINT gotcha**:

CI workflow `build-devcontainer.sh` originally used:
```bash
podman create --name prep ... sleep infinity
podman start prep
podman exec -it prep bash -lc '...'
```

This failed with `Error: can only create exec sessions on running containers:
container state improper`. The Lambda base image (`public.ecr.aws/lambda/python:3.12`)
sets an `ENTRYPOINT` pointing at the Lambda Runtime Interface Emulator. Even
though we overrode `CMD` with `sleep infinity`, the ENTRYPOINT ran first,
tried to invoke the RIE on `sleep infinity` as a "handler", failed, container
exited. Subsequent `podman exec` failed because container wasn't running.

**Fix**: `podman run --entrypoint '[]' ... bash -lc '...'`. The
`--entrypoint '[]'` clears the Lambda ENTRYPOINT. VSCode DevContainers
auto-clears ENTRYPOINT when starting containers, which is why local dev
worked but CI didn't.

**Exercise**: Read `scripts/build-devcontainer.sh` and identify the
`--entrypoint '[]'` line. Remove it mentally and predict what would happen
on the next CI run.

**Case study — ghcr.io auth scopes**:

Local `podman push ghcr.io/arekglinka/lambda_cpp26-dev:latest` returned
`403 Forbidden`. CI workflow's `podman push` worked fine. Cause: the local
`gh auth token` had scopes `admin:public_key, gist, read:org, repo` — missing
`write:packages`. CI uses `GITHUB_TOKEN` (auto-scoped via the workflow's
`permissions: packages: write` block).

Fix: `gh auth refresh --scopes write:packages,read:packages` (interactive
browser flow). Re-login to ghcr.io with the refreshed token.

### 7.4 clangd Version vs C++ Standard Compatibility

System clangd on AL2023 is 15.x (from `clang-tools-extra`). The project uses
`-std=c++26`. Clang 15 doesn't recognize that flag, falls back to default
(c++17 ish), and libstdc++ from GCC 16 conditionally compiles out features
behind `__cplusplus >= 202600L` guards. Result: false-positive errors on
`<optional>`, `<print>`, etc.

**Fix**: `pip install clangd>=19` provides clangd 22.1.1 with full C++26
support. devcontainer.json sets `"clangd.path": "/var/lang/bin/clangd"` to
point at the pip-installed binary.

**Closely related**: `compile_commands.json` must exist for clangd to know
how each TU compiles. Added `set(CMAKE_EXPORT_COMPILE_COMMANDS ON)` to
`src/CMakeLists.txt`. clangd config in `.vscode/settings.json`:
```json
"clangd.arguments": [
  "--compile-commands-dir=${workspaceFolder}/build/Release",
  "--query-driver=/opt/gcc16/bin/g++",
  "-j=4"
]
```

| Resource | Type | Specific Coverage | Link |
|---|---|---|---|
| **clangd — compile_commands.json** | Docs | What it is, where clangd searches, --compile-commands-dir | [clangd.llvm.org/.../compile-commands](https://clangd.llvm.org/design.html) |
| **pip clangd package** | PyPI | Standalone clangd binary distribution (latest LLVM) | [pypi.org/project/clangd](https://pypi.org/project/clangd/) |
| **`src/CMakeLists.txt`** | Source (this repo) | `CMAKE_EXPORT_COMPILE_COMMANDS` line | [`src/CMakeLists.txt`](../src/CMakeLists.txt) |

**Exercise**: Open `src/sum_columns.cpp` in VSCode attached to the container.
Remove `"clangd.path"` from `.vscode/settings.json`. Reload window. Observe
the false-positive errors. Restore the path. Reload. Confirm errors clear.

### 7.5 Mixed Python/C++ Debugging with CodeLLDB

`sum_columns.cpp` is a pybind11 Python extension — you can't "run" it as a
binary. To debug, launch Python under LLDB with the `.so` on PYTHONPATH.
C++ breakpoints set in the editor hit when Python crosses the boundary via
the C Data Interface.

**Launch config** (`.vscode/launch.json` — "Debug pytest (sum_columns module)"):
```json
{
  "type": "lldb",
  "program": "/var/lang/bin/python3.12",
  "args": ["-m", "pytest", "tests/", "-v"],
  "env": {"PYTHONPATH": "${workspaceFolder}/build/Release:${workspaceFolder}"},
  "preLaunchTask": "build-sum-columns",
  "sourceLanguages": ["cpp", "python"]
}
```

Key fields:
- `preLaunchTask: build-sum-columns` — rebuilds the `.so` before launching
- `program: python3.12` — Python launches under LLDB, not the `.so`
- `PYTHONPATH` — makes `import sum_columns` find the `.so`
- `sourceLanguages: ["cpp", "python"]` — both languages show stack frames

**Standalone vs pybind11 detection**: a separate task
(`build-active-standalone-only`) greps the active file for `PYBIND11_MODULE(`
and fails with a clear error pointing to the pytest config — prevents the
confusing "build/src/sum_columns does not exist" error.

| Resource | Type | Specific Coverage | Link |
|---|---|---|---|
| **CodeLLDB MANUAL.md** | Extension docs | Launch config fields, sourceLanguages, noDebug | [github.com/vadimcn/vscode-lldb/blob/master/MANUAL.md](https://github.com/vadimcn/vscode-lldb/blob/master/MANUAL.md) |
| **`.vscode/launch.json`** | Source (this repo) | All four configs (standalone debug/run, pytest debug/run) | [`.vscode/launch.json`](../.vscode/launch.json) |
| **`.vscode/tasks.json`** | Source (this repo) | build-active-cpp, run-active-cpp, build-sum-columns, build-active-standalone-only | [`.vscode/tasks.json`](../.vscode/tasks.json) |
| **`learn/build.sh`** | Script (this repo) | pybind11 auto-dispatch logic | [`learn/build.sh`](../learn/build.sh) |

**Exercise**: Set a breakpoint inside `sum_columns.cpp`'s `sum_numeric_column()`.
Press F5 with "Debug pytest (sum_columns module)" selected. When the breakpoint
hits, examine the call stack — you should see Python frames above the C++ frame
where you paused. Use `py-bt` (if available) or the VSCode variables panel to
inspect both Python and C++ state.

### 7.6 C++ Breakpoint Debugging: Three Compounding Causes (Real Case Study)

This case study captures the **three-hour debugging session** required to make
C++ breakpoints actually hit when Python imported the `.so` under LLDB. The
lesson: a single "missing debug info" symptom had three independent causes
that all needed fixing before breakpoints worked. Each cause alone reproduced
the same symptom.

**Symptom**: User set a breakpoint on `Settings::instance().evaluationDate() = today;`
(line 190 of `sum_columns.cpp`). Pressed F5. pytest ran, all tests passed,
breakpoint never hit.

**Diagnosis path**:
1. Verified line 190 IS in the DWARF line table via `objdump --dwarf=decodedline`.
2. Tested with gdb directly — breakpoint stayed PENDING.
3. Tested with `PyInit_sum_columns` (function name) — that breakpoint HIT, proving
   the .so was loaded and reachable.
4. Discovered the gdb output showed the .so at `/workspaces/lambda_cpp26/sum_columns.so`
   (project root) — NOT the freshly-built `build/Release/` version.

**The three causes** (all fixed in commit `7668474`):

1. **Missing `-g` on compile.** Conan's Release profile doesn't pass `-g`. Even
   though `CMAKE_BUILD_TYPE=Release` allows it, the profile's flags omit it.
   Fix: `target_compile_options(sum_columns PRIVATE -g)` — adds it for just
   our TU; deps stay Release-stripped (multi-hour rebuild avoided).

2. **Missing `-g` on link.** With `-flto=auto` (Conan's Release toolchain
   default), GCC encapsulates debug info in `.gnu.debuglto_*` sections during
   compile. The LTO link-time recompile must transform these into final
   `.debug_*` sections — and that requires `-g` on the link command too. Without
   it, LTO silently drops debug info even though the .o had it. Fix:
   `target_link_options(sum_columns PRIVATE -g)`.

3. **pybind11 3.0 auto-strip.** pybind11 2.x had a `PYBIND11_NO_STRIP` option;
   3.0 removed it. Strip now runs whenever `CMAKE_BUILD_TYPE` isn't
   DEBUG/RELWITHDEBINFO/NONE — no opt-out flag. The Makefile gets a literal
   `/usr/bin/strip` post-build line. Fix: redefine `pybind11_strip` as a
   no-op before calling `pybind11_add_module`:
   ```cmake
   function(pybind11_strip)
   endfunction()
   pybind11_add_module(sum_columns MODULE sum_columns.cpp)
   ```

**Verification commands** (use these when breakpoints don't hit):
```bash
# Check debug sections exist
objdump -h build/Release/sum_columns.cpython-*.so | grep debug_

# Check line table has the source line
objdump --dwarf=decodedline build/Release/sum_columns.cpython-*.so | grep "sum_columns.cpp"

# Check the .so Python actually loads
python3.12 -c "import sum_columns; print(sum_columns.__file__)"
```

| Resource | Type | Specific Coverage | Link |
|---|---|---|---|
| **GCC -flto + debug info** | GCC docs | How LTO handles DWARF, why `-g` is needed at link | [gcc.gnu.org/onlinedocs/gcc/Optimize-Options](https://gcc.gnu.org/onlinedocs/gcc/Optimize-Options.html) |
| **pybind11 3.0 changelog** | Release notes | `PYBIND11_NO_STRIP` removed; strip gated on CMAKE_BUILD_TYPE | [pybind11 changelog](https://github.com/pybind/pybind11/releases) |
| **Commit `7668474`** | Git history | The three-part fix with full reasoning | `git show 7668474` |
| **`src/CMakeLists.txt`** | Source (this repo) | All three fixes inline + explanatory comments | [`src/CMakeLists.txt`](../src/CMakeLists.txt) |

**Exercise**: Read `src/CMakeLists.txt` end-to-end. Identify each of the three
debug-info fixes. For each, predict what would happen if you removed just that
fix and rebuilt. (Hint: cause 3 alone produces a 42M .so; causes 1 or 2 alone
produce a 60M .so without the right `.debug_*` sections.)

### 7.7 Stale `.so` Shadowing (Operational Gotcha)

Even with debug info correct, breakpoints may still fail silently if a stale
`sum_columns.so` exists at the project root. Python's import resolution
searches `PYTHONPATH` entries in order — and the launch config's PYTHONPATH is
`${workspaceFolder}/build/Release:${workspaceFolder}`. A stray `sum_columns.so`
at the project root matches `import sum_columns` BEFORE the build/Release
copy is checked.

**Diagnosis**:
```bash
ls -la /workspaces/lambda_cpp26/*.so 2>/dev/null
python3.12 -c "import sum_columns; print(sum_columns.__file__)"
```

If the printed path ends in `/workspaces/lambda_cpp26/sum_columns.so` (project
root, not `build/Release/`), delete it:
```bash
rm /workspaces/lambda_cpp26/sum_columns.so
```

**Where the stale file comes from**: most likely from an early `conan build .`
run before the explicit `build/Release` layout was established. `*.so` is in
`.gitignore` so it never gets committed — purely a local leftover.

**Prevention pattern**: any time breakpoints silently fail to stop after a
build-system change, run the diagnostic above FIRST. It's a one-liner that
catches ~50% of "breakpoints don't work" reports.

**Exercise**: Read `tests/conftest.py`. Trace the `find_extension()` function
— it searches `build/Release`, `build/`, and `/var/task` but does NOT
check the project root. So pytest via conftest.py finds the right .so. Why
does Python's import system find the wrong one? (Answer: pytest runs the
test file which uses the conftest-injected `ext` fixture, but VSCode's
PYTHONPATH env var is what Python uses for the initial `import sum_columns`
in conftest.py — and that includes `${workspaceFolder}` which has the stale
file.)

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
| [`src/CMakeLists.txt`](../src/CMakeLists.txt) | CMake target structure, `cxx_std_26`, static linking flags, `CMAKE_EXPORT_COMPILE_COMMANDS` |
| [`conanfile.py`](../conanfile.py) | Consumer recipe, boost override, Arrow options |
| [`Containerfile`](../Containerfile) | Multi-stage build, GCC 16 from source, Conan cache mounts, cleanroom test |
| [`recipes/arrow/conanfile.py`](../recipes/arrow/conanfile.py) | Custom Arrow recipe — fixed to canonical ConanCenter pattern (single top-level cmake_file_name) |
| [`recipes/quantlib/conanfile.py`](../recipes/quantlib/conanfile.py) | Custom QuantLib recipe — understand `conandata.yml` dependency |
| [`.devcontainer/devcontainer.json`](../.devcontainer/devcontainer.json) | Prebuilt image (`image:`) + fallback build (`build:`), clangd 22 path, no postCreateCommand |
| [`.devcontainer/Dockerfile`](../.devcontainer/Dockerfile) | GCC 16 from source, clangd 22 via pip, CMake 4.3, no dead `clangd` package (AL2023 fix) |
| [`learn/build.sh`](../learn/build.sh) | Fat convenience library + per-file compile + pybind11 auto-dispatch to make |
| [`.vscode/launch.json`](../.vscode/launch.json) | Four configs — standalone debug/run + pytest debug/run (mixed Python/C++ debugging) |
| [`.vscode/tasks.json`](../.vscode/tasks.json) | build-active-cpp, run-active-cpp, build-sum-columns, build-active-standalone-only (clear-error dispatch) |
| [`scripts/build-devcontainer.sh`](../scripts/build-devcontainer.sh) | CI: rebuild from Dockerfile + bake Conan cache + commit + push (uses --entrypoint '[]') |
| [`scripts/push-devcontainer.sh`](../scripts/push-devcontainer.sh) | Local: commit running container + push to ghcr.io |
| [`scripts/save-devcontainer-tarball.sh`](../scripts/save-devcontainer-tarball.sh) | Airgap/shared-drive tarball + sha256 |
| [`.github/workflows/devcontainer.yml`](../.github/workflows/devcontainer.yml) | CI: auto-rebuild on dev file changes + weekly cron |
| [`setup-podman-wsl.sh`](../setup-podman-wsl.sh) | Ubuntu WSL2 rootful Podman + systemd enable + VSCode Machine settings |

---

## Weekly Schedule (Full-Time)

```
Week 1  │ Phase 1.1–1.2: Move semantics, smart pointers, C++20/26 features
Week 2  │ Phase 1.3 + Phase 2.1–2.2: Static linking, pybind11 core, GIL
Week 3  │ Phase 2.3 + Phase 3.1: PyCapsule protocol (deep study), Arrow architecture
Week 4  │ Phase 3.2: Conan 2 (recipes, build failures Q45–Q53, CMakeDeps fix)
Week 5  │ Phase 4.1–4.2: Lambda fundamentals, Docker builds, glibc/ABI
Week 6  │ Phase 5.1–5.2: Financial math, QuantLib C++ API, integrate into extension
Week 7  │ Phase 6.1: Build the project end-to-end, data flow trace, mock interviews
Week 8  │ Phase 6.2–6.3 + Phase 7: CI pipeline, interview strategy, DevContainer ops
```

## Weekly Schedule (Part-Time, 20 h/week)

```
Weeks  1–2  │ Phase 1 (Modern C++)
Weeks  3–4  │ Phase 2 (pybind11 + PyCapsule)
Weeks  5–7  │ Phase 3 (Arrow + Conan)
Weeks  8–10 │ Phase 4 (Lambda + Docker)
Weeks 11–13 │ Phase 5 (QuantLib)
Weeks 14–16 │ Phase 6 (Integration + Interview prep)
Weeks 17–18 │ Phase 7 (DevContainer ops + tooling case studies)
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
