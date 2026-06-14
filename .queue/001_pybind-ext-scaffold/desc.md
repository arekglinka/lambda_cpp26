# Task: pybind-ext-scaffold
Created: 2026-06-14 (revised from standalone-exe objective)
Status: pending

## Intent
Restructure the project from a standalone C++ executable into a
**Python C++ extension (pybind11)** + **Python Lambda handler**. The C++
extension is PURE COMPUTE — it receives Arrow data from Python (zero-copy
via Arrow C Data Interface), sums columns (+ QuantLib math), returns
results. Python (PyArrow) owns ALL I/O: reading parquet, writing parquet,
S3 access. The near-term milestone: a Python handler loads a LOCAL
parquet file, calls the C++ extension, and prints the output table.

## Architecture decision (recommendation — flag if you disagree)
- **C++ = compute only**: Arrow core + Parquet + QuantLib. NO Arrow S3,
  NO Gandiva/Flight/ORC. Python handles all cloud I/O → no AWS SDK in the
  C++ tree (~30-40MB saved), no static-glibc DNS problem (the entire
  bg_e5db6064 research is mooted by this design).
- **Parquet ON**: C++ can read/write parquet for local `/tmp` workflows;
  also gives the C++ side format flexibility independent of Python.
- **Zero-copy bridge**: Arrow C Data Interface (PyCapsule) between PyArrow
  and the C++ extension. Exact binding pattern pending bg_c31a410b.
- **Extension = pybind11 MODULE** (`.cpython-312-x86_64-linux-gnu.so`):
  Arrow+QuantLib+OpenSSL static-linked INTO the .so; libpython dynamic.

## Context
- Handoff: `.handoff/1781422724.md`. Research: bg_c31a410b (pybind+Arrow
  C Data Interface), bg_7afee6a9 (Lambda Python native ext).
- Current `src/handler.cpp` + `src/CMakeLists.txt` target a standalone
  `lambda_handler` exe linked to aws-lambda-cpp — all replaced.
- `recipes/arrow/`, `recipes/quantlib/` custom recipes STAY.

## Scope IN
- `src/sum_columns.cpp` (was handler.cpp): pybind11 module exposing
  `sum_columns(table_or_arrays) -> table` using Arrow C Data Interface.
  Clean C++26 where it compiles (the .so TU can be c++26; deps at c++17).
- `src/CMakeLists.txt`: build a pybind11 MODULE (`pybind11_add_module`),
  link `arrow_static` + `quantlib`, set `CXX_STANDARD 26` on the module.
- `handler.py`: Lambda handler — `pq.read_table(LOCAL_PARQUET)`,
  call `ext.sum_columns(table)`, `print(result)`.
- `conanfile.py`: Arrow options = core+parquet+compute, s3 OFF, all
  heavy modules OFF. Remove the standalone-exe + aws-lambda-cpp plumbing.
- `data/sample.parquet`: a tiny 2-column fixture for the test (generate
  via a one-liner pyarrow script, committed).

## Scope OUT
- Conan build debugging (task 002).
- Lambda container test (task 003).
- S3 read/write (task 005 stretch).

## Acceptance
- `import sum_columns` works in CPython 3.12; exposes `sum_columns(table)`.
- `handler.py` reads `data/sample.parquet`, calls the ext, prints a table
  with 2 summed columns — correct values.
- `conanfile.py` requires arrow(core+parquet+compute)+quantlib, no
  s3/gandiva/flight/orc/aws-sdk options remain.
- `grep -ri 'gandiva\|flight\|aws-lambda-runtime\|libtorch' src/ conanfile.py`
  is clean.
