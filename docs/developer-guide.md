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

### VSCode debugging

The devcontainer includes the `vadimcn.vscode-lldb` extension for
visual debugging. Create `.vscode/launch.json`:

```json
{
  "version": "0.2.0",
  "configurations": [{
    "name": "Debug extension",
    "type": "cppdbg",
    "request": "launch",
    "program": "/var/lang/bin/python3.12",
    "args": ["-m", "pytest", "tests/test_price_options.py", "-s"],
    "stopAtEntry": false,
    "cwd": "${workspaceFolder}",
    "MIMode": "gdb",
    "setupCommands": [
      {"text": "-enable-pretty-printing"}
    ]
  }]
}
```

Set breakpoints in `sum_columns.cpp` directly in VSCode, then F5.

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
./learn/build.sh                  # builds learn/t1.cpp
./learn/build.sh experiment2.cpp  # any .cpp in learn/
```

**How libdev_lib.so works**: The script finds all Conan-installed `.a`
archives (excluding boost for PIC issues, brotli for duplicates, and
build tools like flex/bison), then links them with `--whole-archive`
into one shared library. This gives scratch files access to EVERY Arrow
and QuantLib symbol — not just the subset the production `.so` uses.

**Why not link against sum_columns.so?** The production `.so` was built
with `--gc-sections` which stripped unreferenced Arrow/QuantLib symbols.
It also has undefined Python C API symbols. Neither makes it suitable as
a general-purpose dev library.

### IDE IntelliSense for scratch files

Files in `learn/` aren't in CMake's `compile_commands.json`, so clangd
uses fallback flags. Two files fix this:

1. **`.clangd`** at project root — adds `-std=c++26` globally
2. **`learn/compile_flags.txt`** — auto-generated by `build.sh` with
   all Conan include paths

Also ensure cpptools isn't conflicting with clangd:
```json
// .vscode/settings.json
"C_Cpp.intelliSenseEngine": "Disabled"
```

### Debugging scratch files

```bash
gdb ./build/learn/t1
# (gdb) break main
# (gdb) run
```

For VSCode, create `.vscode/launch.json`:
```json
{
    "version": "0.2.0",
    "configurations": [{
        "name": "Debug scratch",
        "type": "cppdbg",
        "request": "launch",
        "program": "${workspaceFolder}/build/learn/t1",
        "args": [],
        "cwd": "${workspaceFolder}",
        "MIMode": "gdb"
    }]
}
```
