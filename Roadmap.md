# Roadmap

## Current State

The project delivers a working pybind11 C++ extension (42 MB) that:
- Compiles with GCC 16.1 (C++26 handler TU, C++17 deps)
- Links Arrow C++ 18 (core+parquet+compute) + QuantLib 1.38 statically
- Receives Arrow data via the frozen C Data Interface PyCapsule protocol
- Prices European options using QuantLib Black-Scholes-Merton
- Passes a 3-phase cleanroom test in the pure Lambda Python 3.12 runtime
- Is published to GitHub Releases (v0.0.1) with a CI pipeline for ghcr.io

## Known Draft-State Items

### 1. `-static-libstdc++` not taking effect

**Current**: The `.so` dynamically links `libstdc++.so.6`. We bundle GCC 16's
libstdc++ into the test image as a workaround.

**Problem**: pybind11 or Conan's CMakeToolchain overrides `-static-libstdc++`.
The flag is in `target_link_options` but `readelf -d` shows `libstdc++.so.6`
in NEEDED.

**Fix**: Debug the link command with `cmake --build . -- VERBOSE=1`. Likely
the Conan toolchain adds `-lstdc++` after our `-static-libstdc++`. Force it
via `CMAKE_CXX_STANDARD_LIBRARIES` or link `/opt/gcc16/lib64/libstdc++.a`
directly.

**Priority**: Medium (current workaround works, just less elegant)

### 2. Arrow recipe `source_folder` monkey-patch

**Current**: The Arrow recipe's `build()` method does a `find` + property
override to locate `CMakeLists.txt` because Conan's folder resolution puts
the source at a doubled `cpp/cpp/` path.

**Problem**: Fragile (depends on Conan's internal directory structure) and
ugly.

**Fix**: Investigate why `cmake_layout(self, src_folder="cpp")` resolves
relative to the build area instead of the source area. May be a Conan 2.x
version-specific behavior. Upstream a bug report or use
`self.folders.source = "."` + `add_subdirectory(cpp)` in a wrapper
CMakeLists.txt.

**Priority**: Low (works reliably, just technical debt)

### 3. `__arrow_c_stream__` not supported (Table → C++)

**Current**: The extension handles `RecordBatch.__arrow_c_array__()` but not
`Table.__arrow_c_stream__()`. Python code does `table.to_batches()[0]` as a
workaround.

**Problem**: Tables with multiple chunks lose data (only the first batch
is processed).

**Fix**: Add a fallback in the C++ binding: try `__arrow_c_array__` first,
fall back to `__arrow_c_stream__`, iterate all batches from the stream.

**Priority**: High (correctness issue for multi-chunk data)

### 4. Boost `header_only=True` override not propagating

**Current**: The conanfile sets `boost/1.90.0` with `header_only=True` and
`override=True`, but boost compiles ALL its libraries (~5 min wasted).

**Problem**: The Arrow recipe's own boost requirement overrides
`header_only` back to False.

**Fix**: Set `boost/*:header_only=True` in the Conan profile's `[options]`
section (higher priority than recipe-level options).

**Priority**: Low (5 min build-time waste, no correctness impact)

### 5. re2 → abseil transitive include gap

**Current**: The Arrow recipe injects `-I<abseil>/include` into CXX flags
because the ConanCenter re2 recipe doesn't propagate abseil's headers
transitively.

**Problem**: Blunt instrument (adds include to all TUs, not just those
using re2).

**Fix**: Upstream a fix to the ConanCenter re2 recipe (add
`cpp_info.components["re2"].requires = ["abseil::abseil"]` with
`transitive_headers=True`).

**Priority**: Low (works, just inelegant)

### 6. GitHub Actions workflow untested

**Current**: The release workflow (ci.yml) is written but hasn't been
triggered (no push to `release` branch yet).

**Fix**: Create a `release` branch, push, and verify the workflow runs to
completion. Debug any CI-specific issues (podman version, cache mount
behavior on ephemeral runners).

**Priority**: High (needed for automated releases)

---

## Simplification Opportunities

### A. Replace custom Arrow recipe with ConanCenter

**Why**: The custom recipe requires maintenance (rootpath fixes, source
path monkey-patches, abseil includes). ConanCenter's arrow recipe may have
improved by now.

**When**: When ConanCenter's arrow recipe supports version 18+, has correct
ORC defaults, and properly handles the cpp_info structure.

**Effort**: Medium — test ConanCenter recipe, migrate options, remove
custom recipe.

### B. Drop Parquet from the Arrow build

**Why**: Python (PyArrow) handles all Parquet I/O. The C++ extension only
needs Arrow core (arrays, record batches, C Data Interface). Parquet pulls
in Thrift + its transitive deps.

**Impact**: Smaller dep tree (no Thrift), faster build (~5 min saved),
smaller .so (~5-10 MB saved).

**Effort**: Low — set `parquet=False` in conanfile.py + profile.

### C. Strategy A (pure C Data Interface, no libarrow)

**Why**: For numeric column operations + QuantLib math, you don't need
libarrow at all. Walk `ArrowArray->children[i]->buffers[1]` as raw
`double*` pointers. The .so shrinks from 42 MB to ~15-25 MB (QuantLib only).

**Trade-off**: Lose Arrow compute kernels, typed array API, and C++ Parquet
writing. Must manually handle null bitmaps and type dispatch.

**When**: If binary size or cold start becomes critical.

### D. Use Conan lockfiles for reproducible builds

**Why**: `conan install` resolves versions dynamically. A lockfile
(`conan.lock`) pins the exact dependency graph for reproducibility.

**Effort**: Low — run `conan lock create`, commit the lockfile, use
`--lockfile=conan.lock` in CI.

### E. Multi-arch (arm64 / Graviton)

**Why**: Graviton Lambdas are 20% cheaper and may have faster cold starts.

**Approach**: `podman build --platform linux/arm64` (QEMU emulation on
x86) or native arm64 CI runner. The Containerfile is already
arch-agnostic.

**Effort**: Medium — test on arm64, handle any arch-specific compilation
issues in Arrow/QuantLib.

---

## Future Features

| Feature | Effort | Description |
|---------|--------|-------------|
| S3 round-trip | Low | Python reads from S3 → C++ processes → Python writes to S3. Pure Python changes. |
| Monte Carlo pricing | Medium | Add `monte_carlo_price()` using QuantLib's MCEuropeanEngine. Demonstrates stochastic simulation. |
| Multi-strike options | Low | Price a strip of options at different strikes, return as a multi-row Arrow table. |
| Arrow table output (capsule) | Medium | Export results via `ExportRecordBatch` → PyCapsule for zero-copy return to Python. |
| Real-time data feed | High | Connect to a market data API (yfinance live, Alpha Vantage), stream into the extension. |
| Lambda provisioned concurrency | Low | Configure warm instances to eliminate cold starts for the 42 MB .so. |
| ccache integration | Medium | Mount ccache in the devcontainer for instant C++ recompilation on header changes. |
| clang-tidy static analysis | Low | Add `.clang-tidy` config + CI step for automated code quality checks. |

---

## Architecture Simplification Path

If starting fresh, the simplified architecture would be:

1. **No custom Conan recipes** — use ConanCenter arrow + quantlib directly
2. **No GCC 16 from source** — wait for AL2023 to ship GCC 14+ (C++23 sufficient for most features)
3. **No boost** — Arrow 19+ may remove the boost dependency entirely
4. **No Containerfile complexity** — single-stage build if ConanCenter recipes improve
5. **Strategy A (pure C)** — skip libarrow, walk ArrowArray buffers directly for numeric work

The current complexity exists because GCC 16 is 8 weeks old and ConanCenter recipes haven't caught up. As the ecosystem matures, many workarounds can be removed.
