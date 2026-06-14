# Plan: pybind-ext-scaffold
Updated: 2026-06-14
Research: bg_c31a410b (Arrow C Data Interface / PyCapsule — DEFINITIVE), bg_7afee6a9

## Approach
Build a pybind11 module that receives Arrow data from Python via the
PyCapsule C Data Interface, computes in C++ using the statically-linked
libarrow + QuantLib, and returns results. The capsule protocol is the
HARD BOUNDARY: never pass `arrow::` objects across the Python/C++ line —
only the frozen C structs (`ArrowSchema`/`ArrowArray`) cross. This avoids
the double-Arrow problem (your static libarrow and PyArrow's libarrow
never share symbols; the capsule ABI is frozen so version skew is safe).

## Binding pattern (from research bg_c31a410b §2 Approach B, §4.1 Point72/csp)
- RECEIVE: `py::object` → call `obj.attr("__arrow_c_array__")()` →
  `py::tuple` of (schema_capsule, array_capsule) →
  `PyCapsule_GetPointer(..., "arrow_schema"/"arrow_array")` →
  `arrow::ImportSchema` + `arrow::ImportRecordBatch` (from `<arrow/c/bridge.h>`).
  Import CONSUMES the C structs (calls release). The capsule destructor
  handles the already-released case.
- COMPUTE: operate on the `arrow::RecordBatch` (your libarrow's address
  space) — access columns, sum, run QuantLib math.
- RETURN (simple): sums as `py::dict` {"col_0": X, "col_1": Y} — Python
  prints/builds the output table. (First milestone.)
- RETURN (stretch): build an `arrow::RecordBatch` → `arrow::ExportRecordBatch`
  → wrap in two `py::capsule("arrow_schema"/"arrow_array")` with release
  destructors → return `py::tuple`. PyArrow auto-converts via the protocol.

## Files
- src/sum_columns.cpp (replaces handler.cpp): pybind11 module.
  - `sum_columns(table: object) -> dict` — the milestone function.
  - `sum_columns_arrow(table: object) -> tuple` — stretch (returns capsules).
  - Uses `#include <arrow/c/abi.h>`, `<arrow/c/bridge.h>`, `<arrow/record_batch.h>`.
  - QuantLib stretch: a `black_scholes(...)` binding to prove the link.
  - Compiled at `-std=c++26` (target property); deps at c++17.
- src/CMakeLists.txt: pybind11_add_module (link mechanics in task 002 plan).
- handler.py: Lambda handler — `pq.read_table(local_parquet)` →
  `ext.sum_columns(table)` → print result.
- data/sample.parquet: 2-column Int64 fixture (generate via pyarrow one-liner).
- conanfile.py: arrow(core+parquet+compute, s3 OFF) + quantlib. (task 002.)

## Reference repos (study before coding)
- Point72/csp — cpp/csp/python/adapters/ArrowInputAdapter.h (the gold
  standard capsule import) + ArrowCppNodes.cpp (capsule export).
- apache/arrow-nanoarrow — pure-C alternative (if size forces dropping libarrow).
- duckdb/duckdb-python — stream-based capsule export.

## Steps
- [ ] Generate data/sample.parquet: a tiny pyarrow script creating a 2-col
      Int64 table (e.g. col_0=[1,2,3,4,5], col_1=[10,10,10,10,10]),
      sums = 15 and 50. Commit the fixture.
- [ ] Write src/sum_columns.cpp:
      ```cpp
      #include <pybind11/pybind11.h>
      #include <arrow/c/abi.h>
      #include <arrow/c/bridge.h>
      #include <arrow/record_batch.h>
      #include <Python.h>
      namespace py = pybind11;

      static std::shared_ptr<arrow::RecordBatch> import_record_batch(py::object obj) {
          py::tuple tup = obj.attr("__arrow_c_array__")().cast<py::tuple>();
          ArrowSchema* cs = reinterpret_cast<ArrowSchema*>(
              PyCapsule_GetPointer(tup[0].ptr(), "arrow_schema"));
          ArrowArray* ca = reinterpret_cast<ArrowArray*>(
              PyCapsule_GetPointer(tup[1].ptr(), "arrow_array"));
          auto schema = arrow::ImportSchema(cs).ValueOrDie();
          return arrow::ImportRecordBatch(ca, schema).ValueOrDie();
      }

      PYBIND11_MODULE(sum_columns, m) {
          m.doc() = "Sum Arrow columns via C++26 + Arrow C Data Interface";
          m.def("sum_columns", [](py::object table_like) -> py::dict {
              auto batch = import_record_batch(table_like);
              py::dict out;
              for (int i = 0; i < batch->num_columns(); ++i) {
                  auto col = batch->column(i);
                  double sum = 0;
                  for (int64_t j = 0; j < col->length(); ++j)
                      sum += col->GetScalar(j)->ValueOrDie()->is_valid
                             ? /*typed access*/ 0 : 0;  // use numeric cast per type
                  out[batch->schema()->field(i)->name().c_str()] = sum;
              }
              return out;
          });
      }
      ```
      (Refine the per-type numeric access — use `arrow::NumericArray<T>` or
      `VisitDataInline`; the skeleton above is illustrative. See Point72/csp
      for the production pattern.)
- [ ] Write handler.py:
      ```python
      import json, pyarrow.parquet as pq
      import sum_columns as ext
      def lambda_handler(event, context):
          t = pq.read_table("/var/task/data/sample.parquet")
          result = ext.sum_columns(t)
          print("RESULT:", result)
          return {"statusCode": 200, "body": json.dumps(result)}
      ```
- [ ] Edit conanfile.py per task 002 (arrow core+parquet+compute, s3 OFF).
- [ ] `grep -ri 'gandiva\|flight\|aws-lambda-runtime\|libtorch' src/ conanfile.py` clean.

## Notes
- The capsule IMPORT consumes the C structs. Do NOT call `c_array->release()`
  manually — ImportRecordBatch does it. The PyCapsule destructor must guard
  against double-release (check `->release != NULL`).
- PyArrow ≥ 14.0 required for `__arrow_c_array__` (frozen since). Lambda
  Python runtime ships a recent PyArrow via pip — pin `pyarrow>=15.0`.
- For the stretch `sum_columns_arrow` (capsule EXPORT): malloc the
  ArrowSchema/ArrowArray, ExportRecordBatch into them, wrap each in
  py::capsule with a release destructor that frees the struct. Return the
  tuple; PyArrow's `pa.record_batch(tuple)` or an object implementing
  `__arrow_c_array__` consumes it.
- If size becomes critical later: drop libarrow entirely (Strategy 1 from
  research) — walk `ArrowArray->children[i]->buffers[1]` as raw `int64_t*`.
  No Conan Arrow build needed; .so shrinks to QuantLib-only (~15-25MB).
  Documented as the fallback; NOT the default (you wanted Arrow C++).
