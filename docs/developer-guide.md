# Developer Guide: Debugging & Profiling

## Debugging

### GDB with Python extensions

The devcontainer includes gdb with Python debug support. To debug the
C++ extension from Python:

```bash
# Launch Python under gdb:
gdb --args python3.12 -c "
import pyarrow.parquet as pq
import sum_columns as ext
t = pq.read_table('data/stock_prices.parquet')
r = ext.price_options(t.to_batches()[0])
print(r)
"

# Inside gdb:
(gdb) break sum_columns.cpp:155          # price_options function
(gdb) break QuantLib::VanillaOption::NPV # QuantLib method
(gdb) run
```

**Cross-language stack navigation** (GDB Python helpers):

| Command | Action |
|---------|--------|
| `py-bt` | Python backtrace from current C frame |
| `py-up` / `py-down` | Step between Python and C frames |
| `py-locals` | Print Python local variables |
| `py-list` | Show Python source at current position |

### VSCode debugging (CodeLLDB)

The devcontainer ships `vadimcn.vscode-lldb` (CodeLLDB) for visual debugging.
`.vscode/launch.json` provides four configs covering both project file types:

| Config | When to use | What it does |
|--------|-------------|--------------|
| **Debug active C++ file** | Standalone executables (files with `main()` in `src/` or `learn/`) | Builds via `learn/build.sh`, attaches LLDB to the binary |
| **Run active C++ file (no debug)** | Same as above, no breakpoints | Same build, `noDebug: true` |
| **Debug pytest (sum_columns module)** | pybind11 module work (`src/sum_columns.cpp`) | Builds `.so` via `make`, launches `python -m pytest` under LLDB; C++ breakpoints hit when pytest calls into the module |
| **Run pytest (no debug)** | Same as above, no breakpoints | Same build, runs pytest under LLDB without debug |

**Picking the right config**: F5 launches whatever's selected in the Run &
Debug dropdown (`Ctrl+Shift+D`). Switch configs from the dropdown at the top
of that panel. VSCode remembers the selection per-workspace.

**Setting breakpoints in `sum_columns.cpp`**: open the file, click the gutter
on any line inside `sum_columns()` or `price_options()`. Launch "Debug pytest
(sum_columns module)". When pytest calls `ext.sum_columns(batch)` or
`ext.price_options(batch)`, execution pauses at your breakpoint — full call
stack shows both Python and C++ frames.

**Why a separate config for pybind11 modules**: a `.so` is a Python extension,
not a standalone binary. You can't "run" it directly — you run Python code
that imports it (pytest). The standalone configs look for `build/<folder>/<name>`
which doesn't exist for modules (they ship as `build/Release/<name>.cpython-*.so`).

If you pick "Debug active C++ file" while `sum_columns.cpp` is open, the
preLaunchTask (`build-active-standalone-only`) detects `PYBIND11_MODULE(` in
the source and fails with a clear error pointing to the right config.

---

## Sanitizers

### AddressSanitizer + UndefinedBehaviorSanitizer

Build Python from source with ASan (system Python won't work — all loaded
libraries must be instrumented):

```bash
# Inside the devcontainer:
cd /tmp && curl -sL https://www.python.org/ftp/python/3.12.3/Python-3.12.3.tgz | tar xz
cd Python-3.12.3
./configure --with-address-sanitizer --with-pydebug --prefix=$HOME/python-asan
make -j$(nproc) && make install

# Build the extension with sanitizer flags:
cmake -B build-asan -DCMAKE_BUILD_TYPE=Debug \
  -DCMAKE_CXX_FLAGS="-fsanitize=address,undefined -fno-omit-frame-pointer -g" \
  -DCMAKE_SHARED_LINKER_FLAGS="-fsanitize=address,undefined" \
  src/
cmake --build build-asan

# Run tests under ASan:
$HOME/python-asan/bin/python3 -c "import sys; sys.path.insert(0, 'build-asan'); import sum_columns"
```

### Suppressions for false positives

Create `asan_suppressions.supp`:
```
fun:pybind11::internal::*
fun:arrow::PoolBase::*
```

Run with:
```bash
ASAN_OPTIONS="suppressions=asan_suppressions.supp:detect_leaks=1" \
  python-asan/bin/python3 tests/run_tests.py
```

---

## Performance Profiling

### perf + FlameGraph (Python 3.12 native support)

Python 3.12+ emits perf map files, so `perf record` shows Python AND C++
function names interleaved:

```bash
# Allow non-root profiling:
echo 1 | sudo tee /proc/sys/kernel/perf_event_paranoid

# Record (mixed Python + C++ call graph):
PYTHONPERFSUPPORT=1 perf record -F 9999 -g --call-graph dwarf \
  -- python3.12 -c "
import sum_columns as ext
import pyarrow.parquet as pq
t = pq.read_table('data/stock_prices.parquet')
for _ in range(10000):
    ext.price_options(t.to_batches()[0])
"

# Terminal report:
perf report -g --stdio

# FlameGraph:
git clone https://github.com/brendangregg/FlameGraph
perf script | FlameGraph/stackcollapse-perf.pl | FlameGraph/flamegraph.pl > flame.svg
```

Open `flame.svg` in a browser — Python frames show as
`py:function_name:/path/file.py`, C++ frames show symbol names.

### py-spy (no root needed)

```bash
pip install py-spy
py-spy record --native -o profile.svg -- python3.12 benchmark.py
```

`--native` is essential — without it, C++ frames are invisible.

### Hotspot GUI

```bash
sudo dnf install hotspot
hotspot perf.data
```

Provides flame graph, top-down/bottom-up, per-source annotation, caller/callee.

---

## Static Analysis

### clang-tidy

Create `.clang-tidy` at project root:

```yaml
Checks: >
  -*,
  bugprone-*,
  modernize-*,
  performance-*,
  readability-*,
  cert-*,
  -modernize-use-trailing-return-type,
  -readability-magic-numbers,
  -readability-identifier-length
```

CMake integration (per-target, avoids analyzing Arrow/QuantLib headers):

```cmake
find_program(CLANG_TIDY_EXE NAMES "clang-tidy")
if(CLANG_TIDY_EXE)
    set_target_properties(sum_columns PROPERTIES
        CXX_CLANG_TIDY "${CLANG_TIDY_EXE};-header-filter=^$(pwd)/src/")
endif()
```

Run: `cmake -B build-tidy && cmake --build build-tidy`

### cppcheck

```bash
cppcheck --std=c++26 --enable=all --inconclusive \
  --suppress=missingInclude \
  --project=build/compile_commands.json
```

---

## Build Acceleration

### ccache

Add to `src/CMakeLists.txt`:
```cmake
find_program(CCACHE_PROGRAM ccache)
if(CCACHE_PROGRAM)
    set(CMAKE_CXX_COMPILER_LAUNCHER "${CCACHE_PROGRAM}")
    set(ENV{CCACHE_BASEDIR} "${CMAKE_SOURCE_DIR}")
    set(ENV{CCACHE_SLOPPINESS} "include_file_ctime,include_file_mtime,time_macros,pch_defines")
endif()
```

Install: `dnf install ccache` in the devcontainer.

**Conan 2 note**: Conan's hash-based package paths confuse ccache. Setting
`CCACHE_BASEDIR` + `CCACHE_SLOPPINESS` (as above) mitigates this.

### Precompiled headers

```cmake
target_precompile_headers(sum_columns PRIVATE
    <vector> <string> <memory> <cmath> <optional>
    <pybind11/pybind11.h>
)
```

Reduces compile time for `sum_columns.cpp` (which pulls in `<ql/quantlib.hpp>`
+ Arrow headers — heavy template instantiation).

---

## Memory Leak Detection

### Valgrind with Python

```bash
# CRITICAL: disable pymalloc so Valgrind sees all allocations
PYTHONMALLOC=malloc valgrind --tool=memcheck \
    --leak-check=full \
    --show-leak-kinds=definite \
    --track-origins=yes \
    --suppressions=$HOME/valgrind-python.supp \
    --error-exitcode=99 \
    python3.12 -m pytest tests/ -x

# Get the CPython suppressions file:
wget -O ~/valgrind-python.supp \
    https://raw.githubusercontent.com/python/cpython/main/Misc/valgrind-python.supp
# Edit: uncomment PyObject_Free and PyObject_Realloc blocks
```

### Quick leak check (pybind11 pattern)

```python
# Insert infinite loop, watch RES in top:
import sum_columns as ext
import pyarrow.parquet as pq
t = pq.read_table("data/stock_prices.parquet")
b = t.to_batches()[0]
while True:          # watch top -p $(pgrep python)
    ext.price_options(b)
    ext.sum_columns(b)
```

If RES climbs continuously → memory leak in the extension.
If RES stabilizes after a few iterations → no leak.

---

## Quick Reference

| Task | Tool | Command |
|------|------|---------|
| Debug crash | gdb | `gdb --args python3.12 script.py` |
| Debug in IDE | VSCode + lldb | F5 with launch.json |
| Memory errors | ASan | Build with `-fsanitize=address` |
| Performance | perf + FlameGraph | `PYTHONPERFSUPPORT=1 perf record -g` |
| Quick profile | py-spy | `py-spy record --native` |
| Code quality | clang-tidy | `CMAKE_CXX_CLANG_TIDY=clang-tidy` |
| Memory leaks | Valgrind | `PYTHONMALLOC=malloc valgrind --leak-check=full` |
| Faster builds | ccache | `CMAKE_CXX_COMPILER_LAUNCHER=ccache` |

---

## Scratch File Development

### The `learn/` directory

Experiment files go in `learn/` — physically separated from `src/` so
`conan build .` never compiles them. Each file has a standalone `main()`.

### Quick build via `learn/build.sh`

The script creates a fat convenience library (`libdev_lib.so`) once,
then every scratch file compiles against it in seconds:

```bash
./learn/build.sh                     # builds learn/t1.cpp (default)
./learn/build.sh learn/t1.cpp        # explicit learn/ path
./learn/build.sh src/t1.cpp          # any path relative to project root
./learn/build.sh src/sum_columns.cpp # pybind11 module — auto-dispatched
```

**Output paths preserve source folder structure** to avoid collisions:
- `learn/t1.cpp` → `build/learn/t1`
- `src/t1.cpp` → `build/src/t1`
- `src/sum_columns.cpp` → `build/Release/sum_columns.cpython-312-*.so` (via make)

**pybind11 auto-dispatch**: if the source file contains `PYBIND11_MODULE(`,
build.sh routes to `make -C build/Release <basename>` instead of direct g++.
This is required because pybind11 headers come from pip (not Conan cache),
and the resulting `.so` is a Python extension, not a standalone binary.

**How libdev_lib.so works**: The script finds all Conan-installed `.a`
archives (excluding boost for PIC issues, brotli for duplicates, and
build tools like flex/bison), then links them with `--whole-archive`
into one shared library. This gives scratch files access to EVERY Arrow
and QuantLib symbol — not just the subset the production `.so` uses.

**Why not link against sum_columns.so?** The production `.so` was built
with `--gc-sections` which stripped unreferenced Arrow/QuantLib symbols.
It also has undefined Python C API symbols. Neither makes it suitable as
a general-purpose dev library.

### IDE IntelliSense (clangd 22 via pip)

The container's system clangd (15.x from `clang-tools-extra`) doesn't
recognize `-std=c++26` and falls back to an earlier default, producing
false-positive errors on `<optional>`, `<print>`, etc. The Dockerfile
installs clangd 22 via pip (`/var/lang/bin/clangd`), and devcontainer.json
points `clangd.path` at it.

**Two include-resolution mechanisms** (both required):
1. **`compile_commands.json`** — generated by CMake for `src/sum_columns.cpp`
   after `set(CMAKE_EXPORT_COMPILE_COMMANDS ON)` in `src/CMakeLists.txt`.
   Lives at `build/Release/compile_commands.json`. clangd's
   `--compile-commands-dir` points there.
2. **`learn/compile_flags.txt`** — auto-regenerated by every `build.sh` run
   with the current Conan cache layout. clangd picks this up for files
   outside CMake's graph (i.e., `learn/*.cpp` and `src/t1.cpp`).

Also ensure cpptools isn't conflicting with clangd:
```json
// .vscode/settings.json
"C_Cpp.intelliSenseEngine": "Disabled"
```

### VSCode build & run shortcuts

| Shortcut | Action |
|----------|--------|
| `Ctrl+Shift+B` | Build active C++ file (default build task — auto-dispatches to make for pybind11, g++ for executables) |
| `Ctrl+Shift+P` → `Tasks: Run Task` → `run-active-cpp` | Build + run active standalone file in dedicated terminal |
| `Ctrl+Shift+P` → `Tasks: Run Task` → `build-sum-columns` | Rebuild the pybind11 `.so` via Conan's CMake (incremental) |
| `F5` (with config picked in Run & Debug dropdown) | Build + launch under LLDB; see VSCode debugging section above |
| `Ctrl+F5` | Same as F5 but with `noDebug: true` (run without breakpoints) |

### Debugging scratch files

Standalone executables land at `build/<source_folder>/<basename>`, e.g.
`build/learn/t1` or `build/src/t1`. Use the "Debug active C++ file" launch
config — `preLaunchTask` builds via `learn/build.sh`, then LLDB attaches.

For terminal debugging:
```bash
gdb ./build/learn/t1
# (gdb) break main
# (gdb) run
```
