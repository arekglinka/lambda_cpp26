/// @file sum_columns.cpp
/// pybind11 module: sum Arrow columns via C++26 + Arrow C Data Interface.
///
/// The C Data Interface (PyCapsule protocol) is the HARD BOUNDARY between
/// Python (PyArrow) and this C++ extension.  Never pass arrow:: objects across
/// the Python/C++ line — only the frozen C structs (ArrowSchema / ArrowArray)
/// cross, so our static libarrow and PyArrow's libarrow never share symbols.
///
/// Compile this TU at -std=c++26 (via CMake target property).  The dependency
/// graph (Arrow, QuantLib, …) compiles at c++17 per the Conan profile.

#include <pybind11/pybind11.h>

#include <arrow/c/abi.h>
#include <arrow/c/bridge.h>
#include <arrow/array.h>
#include <arrow/record_batch.h>
#include <arrow/type.h>

#include <Python.h>

#include <cstdint>
#include <optional>
#include <print>
#include <stdexcept>
#include <string>

namespace py = pybind11;

// ---------------------------------------------------------------------------
//  Capsule extraction helpers
// ---------------------------------------------------------------------------

/// Extract a raw pointer from a named PyCapsule.
/// Throws if the capsule is null or the name does not match.
static void* capsule_ptr(py::handle h, const char* name) {
    void* ptr = PyCapsule_GetPointer(h.ptr(), name);
    if (!ptr)
        throw std::runtime_error(
            std::string("PyCapsule '") + name + "' not found or invalid");
    return ptr;
}

/// Import an Arrow RecordBatch from a Python object that implements
/// __arrow_c_array__ (returns a (schema_capsule, array_capsule) tuple).
///
/// ImportSchema / ImportRecordBatch CONSUME the C structs (they call the
/// release callback).  The PyCapsule destructors handle the already-released
/// case.
static std::shared_ptr<arrow::RecordBatch> import_record_batch(py::object obj) {
    py::object result = obj.attr("__arrow_c_array__")();
    py::tuple tup = result.cast<py::tuple>();
    if (tup.size() != 2)
        throw std::runtime_error(
            "__arrow_c_array__() must return a 2-tuple (schema, array)");

    auto* c_schema = static_cast<ArrowSchema*>(capsule_ptr(tup[0], "arrow_schema"));
    auto* c_array  = static_cast<ArrowArray*>(capsule_ptr(tup[1], "arrow_array"));

    auto schema_res = arrow::ImportSchema(c_schema);
    if (!schema_res.ok())
        throw std::runtime_error("Schema import failed: " + schema_res.status().ToString());

    auto batch_res = arrow::ImportRecordBatch(c_array, schema_res.ValueUnsafe());
    if (!batch_res.ok())
        throw std::runtime_error("Batch import failed: " + batch_res.status().ToString());

    return batch_res.ValueUnsafe();
}

// ---------------------------------------------------------------------------
//  Column summation
// ---------------------------------------------------------------------------

/// Sum a numeric Arrow column into a double.
/// Returns std::nullopt for non-numeric types (caller reports "unsupported").
static std::optional<double> sum_numeric_column(
    const std::shared_ptr<arrow::Array>& col)
{
    const int64_t n = col->length();
    double sum = 0.0;

    switch (col->type_id()) {
    case arrow::Type::INT64: {
        auto a = std::static_pointer_cast<arrow::Int64Array>(col);
        for (int64_t i = 0; i < n; ++i)
            if (a->IsValid(i)) sum += static_cast<double>(a->Value(i));
        break;
    }
    case arrow::Type::INT32: {
        auto a = std::static_pointer_cast<arrow::Int32Array>(col);
        for (int64_t i = 0; i < n; ++i)
            if (a->IsValid(i)) sum += static_cast<double>(a->Value(i));
        break;
    }
    case arrow::Type::DOUBLE: {
        auto a = std::static_pointer_cast<arrow::DoubleArray>(col);
        for (int64_t i = 0; i < n; ++i)
            if (a->IsValid(i)) sum += a->Value(i);
        break;
    }
    case arrow::Type::FLOAT: {
        auto a = std::static_pointer_cast<arrow::FloatArray>(col);
        for (int64_t i = 0; i < n; ++i)
            if (a->IsValid(i)) sum += static_cast<double>(a->Value(i));
        break;
    }
    default:
        return std::nullopt;
    }
    return sum;
}

// ---------------------------------------------------------------------------
//  pybind11 module
// ---------------------------------------------------------------------------

PYBIND11_MODULE(sum_columns, m) {
    m.doc() = "Sum Arrow columns via C++26 + Arrow C Data Interface (zero-copy)";

    m.def(
        "sum_columns",
        [](py::object table_like) -> py::dict {
            auto batch = import_record_batch(table_like);

            std::println(stderr,
                "[sum_columns] batch: {} rows x {} columns",
                batch->num_rows(), batch->num_columns());

            py::dict result;
            for (int i = 0; i < batch->num_columns(); ++i) {
                auto col    = batch->column(i);
                auto name   = batch->schema()->field(i)->name();
                auto summed = sum_numeric_column(col);
                if (summed)
                    result[py::str(name)] = summed.value();
                else
                    result[py::str(name)] = py::str(
                        "unsupported type: " + col->type()->ToString());
            }
            return result;
        },
        py::arg("table_like"),
        "Sum all numeric columns of an Arrow table or record batch.\n\n"
        "Args:\n"
        "    table_like: any object implementing __arrow_c_array__\n"
        "                (pyarrow.Table, RecordBatch, Array, etc.)\n\n"
        "Returns:\n"
        "    dict[str, float | str] — column name to sum, or 'unsupported'.\n");
}
