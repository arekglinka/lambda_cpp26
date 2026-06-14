# Contributing

## Quick Start

### Option A: VSCode DevContainer (recommended)

1. Install [Docker](https://docs.docker.com/get-docker/) or [Podman](https://podman.io/getting-started/)
2. Open the repo in VSCode
3. Install the "Dev Containers" extension
4. `Ctrl+Shift+P` → "Reopen in Container"

The container builds GCC 16 from source on first open (~10 min, cached after). It auto-runs `conan install + build` on creation. You get clangd IntelliSense, gdb, and pytest ready.

```bash
# Inside the devcontainer:
pytest tests/                          # run the test suite
conan install . --build=missing && conan build .  # rebuild after C++ changes
```

### Option B: Podman + local Python (fastest iteration)

Build the `.so` once in the container, then test locally:

```bash
# In the project root:
make build                             # builds .so via podman (first run ~40 min)

# Set up local Python:
uv venv --python 3.12 .venv
source .venv/bin/activate
uv pip install pyarrow

# Copy .so into venv site-packages OR set PYTHONPATH:
cp sum_columns.so .venv/lib/python3.12/site-packages/

# Now iterate on Python-side changes instantly:
python handler.py
pytest tests/
```

### Option C: Full container pipeline (CI-equivalent)

```bash
make ci    # build → cleanroom test → size budget check
make test  # build + run test stage only
make run   # start RIE + curl invoke (local Lambda emulator)
```

## Build System

### The Containerfile (two stages)

```
Stage 1 (builder):  lambda/python:3.12 → GCC 16 from source → Conan deps → .so
Stage 2 (test):     lambda/python:3.12 → PyArrow + .so + handler.py + data/ → assertions
```

The builder stage uses `--mount=type=cache,target=/root/.conan2` on all Conan steps. This persists built packages across rebuilds. Only changed recipes recompile (~2-5 min for Arrow vs 40+ min for a cold build).

**GCC 16 layer**: Cached as a Docker layer after first build. Do NOT modify lines 18-31 of Containerfile unless absolutely necessary — any change triggers a 10-minute GCC rebuild.

### Conan dependency management

Custom recipes live in `recipes/arrow/` and `recipes/quantlib/` (ConanCenter versions are stale or broken). Each recipe has:
- `conanfile.py` — the recipe logic (options, generate, build, package_info)
- `conandata.yml` — source download URLs (version-pinned)

**To update a dependency version:**

1. Edit `conandata.yml` with the new version + URL:
   ```yaml
   sources:
     "1.39":
       url: https://github.com/lballabio/QuantLib/archive/refs/tags/v1.39.tar.gz
   ```

2. Update the version in the recipe's `version` attribute AND in `conanfile.py`'s `requires()`.

3. If the new version needs recipe changes (new CMake options, different directory structure), update `conanfile.py`.

4. Rebuild:
   ```bash
   conan export recipes/quantlib    # re-export the updated recipe
   conan install . --build=missing  # rebuild only the changed package
   ```

5. Verify the cleanroom test still passes: `make test`.

**To add a new dependency:**

1. Check ConanCenter first: `conan search <name> -r conancenter`
2. If ConanCenter has it, add to `conanfile.py`'s `requires()`.
3. If custom recipe needed, create `recipes/<name>/conanfile.py` + `conandata.yml`.
4. `conan export recipes/<name>` then `conan install . --build=missing`.

### Conan profile (profiles/al2023)

```
[settings]
compiler=gcc
compiler.version=16
compiler.cppstd=17          ← deps compile at C++17; our TU overrides to C++26
compiler.libcxx=libstdc++11
build_type=Release

[options]
arrow/*:gandiva=False       ← module disables (in profile to keep conanfile.py clean)
arrow/*:flight=False
arrow/*:s3=False
arrow/*:orc=False
```

**Why cppstd=17?** Arrow and QuantLib are tested at C++17. Our handler TU (`sum_columns.cpp`) overrides to C++26 via `target_compile_features(sum_columns PRIVATE cxx_std_26)` in CMakeLists.txt. This is ABI-safe within GCC 16 (the ABI break is cross-GCC-version, not cross-std).

## Adapting to Amazon Linux Changes

### New AL2023 minor update

AL2023 receives quarterly updates that may change:
- **glibc version** (currently 2.34) — check `ldd --version` in the new image
- **GCC version** (currently 11.2) — affects the stage-1 bootstrap compiler
- **Package availability** — `dnf install` package names may change

**To adapt:**

1. Pull the new base image: `podman pull public.ecr.aws/lambda/python:3.12`
2. Check glibc: `podman run --rm --entrypoint sh public.ecr.aws/lambda/python:3.12 -c 'ldd --version'`
3. If glibc changed, verify the `.so` still resolves all symbols: `ldd sum_columns.so`
4. If GCC changed (affects bootstrap), the GCC 16 from-source build may need configure flag adjustments
5. Run the full pipeline: `make ci`
6. If the cleanroom test passes, you're compatible

### Pinning the base image

To avoid surprise breakage from AL2023 updates, pin the image digest:

```dockerfile
FROM public.ecr.aws/lambda/python:3.12@sha256:<digest> AS builder
```

Get the digest: `podman inspect public.ecr.aws/lambda/python:3.12 --format '{{.Digest}}'`

### Migrating to a new AL version (e.g., AL2025)

If AWS releases a new Amazon Linux version:

1. Update the FROM in both Containerfile stages
2. Re-verify: `dnf install` package names (may differ), glibc version, GCC version
3. The `--mount=type=cache` on `/root/.conan2` must be cleared (new glibc = new binary compatibility = all packages need rebuilding): `podman build --no-cache`
4. Update the profiles/ filename and documentation references

## Testing

### pytest suite (developer tests)

```bash
pytest tests/ -v                          # all tests
pytest tests/test_sum_columns.py -v       # column sum tests only
pytest tests/test_price_options.py -v     # QuantLib pricing tests
```

Tests auto-skip if the `.so` isn't built (with a helpful message).

### Cleanroom test (integration gate)

```bash
make test   # builds the test stage (includes cleanroom assertions in the Containerfile)
```

The cleanroom test verifies:
1. `.so` imports in pure lambda/python:3.12 (no dev packages)
2. `sum_columns` produces correct sums (col_0=15.0, col_1=50.0)
3. `price_options` produces valid option prices (positive, put-call parity holds)
4. Results parquet writes and reads back correctly
5. `ldd` shows no third-party shared library deps

### Size budget

The `.so` must stay under 80 MB (checked by `make ci`). Current size: 42 MB (Arrow + QuantLib).

## Code Conventions

- **C++**: C++26 for the handler TU, C++17 for deps. Use `std::print`, `std::optional`, `std::span` where natural.
- **Python**: Type hints, `if __name__ == "__main__"`, pytest for tests.
- **Conan recipes**: `conandata.yml` for version-specific data, `cmake_layout()` for folder management.
- **Containerfile**: Layer ordering: system deps → GCC → pip → recipes → source → build. Each layer should be independently cacheable.
- **Commits**: Conventional Commits (`feat:`, `fix:`, `docs:`, `build:`, `ci:`).
