/// @file sum_columns.cpp
/// pybind11 module: Arrow column operations + QuantLib option pricing.
///
/// The C Data Interface (PyCapsule protocol) is the HARD BOUNDARY between
/// Python (PyArrow) and this C++ extension.  Never pass arrow:: objects across
/// the Python/C++ line — only the frozen C structs (ArrowSchema / ArrowArray)
/// cross, so our static libarrow and PyArrow's libarrow never share symbols.

#include <pybind11/pybind11.h>

#include <arrow/c/abi.h>
#include <arrow/c/bridge.h>
#include <arrow/array.h>
#include <arrow/record_batch.h>
#include <arrow/type.h>

#include <Python.h>

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <numeric>
#include <optional>
#include <print>
#include <stdexcept>
#include <string>
#include <vector>

#include <ql/quantlib.hpp>

namespace py = pybind11;

// ---------------------------------------------------------------------------
//  Capsule extraction helpers
// ---------------------------------------------------------------------------

static void* capsule_ptr(py::handle h, const char* name) {
    void* ptr = PyCapsule_GetPointer(h.ptr(), name);
    if (!ptr)
        throw std::runtime_error(
            std::string("PyCapsule '") + name + "' not found or invalid");
    return ptr;
}

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
//  Column extraction + summation
// ---------------------------------------------------------------------------

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

static std::vector<double> extract_double_column(
    const std::shared_ptr<arrow::RecordBatch>& batch,
    const std::string& name)
{
    for (int i = 0; i < batch->num_columns(); ++i) {
        if (batch->schema()->field(i)->name() != name) continue;
        auto col = batch->column(i);
        std::vector<double> vals;
        if (col->type_id() == arrow::Type::DOUBLE) {
            auto a = std::static_pointer_cast<arrow::DoubleArray>(col);
            vals.reserve(a->length());
            for (int64_t j = 0; j < a->length(); ++j)
                if (a->IsValid(j)) vals.push_back(a->Value(j));
        } else if (col->type_id() == arrow::Type::FLOAT) {
            auto a = std::static_pointer_cast<arrow::FloatArray>(col);
            vals.reserve(a->length());
            for (int64_t j = 0; j < a->length(); ++j)
                if (a->IsValid(j)) vals.push_back(static_cast<double>(a->Value(j)));
        } else {
            throw std::runtime_error("column '" + name + "' is not float/double");
        }
        return vals;
    }
    throw std::runtime_error("column '" + name + "' not found");
}

// ---------------------------------------------------------------------------
//  QuantLib option pricing
// ---------------------------------------------------------------------------

static double historical_volatility(const std::vector<double>& prices)
{
    if (prices.size() < 2) return 0.0;
    std::vector<double> logret(prices.size() - 1);
    for (size_t i = 0; i < logret.size(); ++i)
        logret[i] = std::log(prices[i + 1] / prices[i]);
    double mean = std::accumulate(logret.begin(), logret.end(), 0.0) / logret.size();
    double sq = 0.0;
    for (double r : logret) sq += (r - mean) * (r - mean);
    return std::sqrt(sq / static_cast<double>(logret.size() - 1)) * std::sqrt(252.0);
}

// ---------------------------------------------------------------------------
//  pybind11 module
// ---------------------------------------------------------------------------

PYBIND11_MODULE(sum_columns, m) {
    m.doc() = "Arrow column ops + QuantLib option pricing via C Data Interface";

    m.def(
        "sum_columns",
        [](py::object table_like) -> py::dict {
            auto batch = import_record_batch(table_like);
            std::println(stderr, "[sum_columns] {} rows x {} cols",
                         batch->num_rows(), batch->num_columns());
            py::dict result;
            for (int i = 0; i < batch->num_columns(); ++i) {
                auto col = batch->column(i);
                auto name = batch->schema()->field(i)->name();
                auto summed = sum_numeric_column(col);
                result[py::str(name)] = summed
                    ? py::cast(summed.value())
                    : py::str("unsupported: " + col->type()->ToString());
            }
            return result;
        },
        py::arg("table_like"),
        "Sum all numeric columns of an Arrow RecordBatch/Table.");

    m.def(
        "price_options",
        [](py::object table_like,
           double risk_free_rate,
           int maturity_days) -> py::dict {
            auto batch = import_record_batch(table_like);
            auto prices = extract_double_column(batch, "close");

            double spot = prices.back();
            double vol  = historical_volatility(prices);
            double strike = spot;

            using namespace QuantLib;
            Date today = Date::todaysDate();
            Settings::instance().evaluationDate() = today;
            DayCounter dc = Actual365Fixed();
            Date maturity = today + Period(maturity_days, Days);

            Handle<Quote> spotH(ext::make_shared<SimpleQuote>(spot));
            Handle<YieldTermStructure> divTS(
                ext::make_shared<FlatForward>(today, 0.0, dc));
            Handle<YieldTermStructure> rfrTS(
                ext::make_shared<FlatForward>(today, risk_free_rate, dc));
            Handle<BlackVolTermStructure> volTS(
                ext::make_shared<BlackConstantVol>(
                    today, NullCalendar(), vol, dc));

            auto proc = ext::make_shared<BlackScholesMertonProcess>(
                spotH, divTS, rfrTS, volTS);
            auto engine = ext::make_shared<AnalyticEuropeanEngine>(proc);

            auto payoffC = ext::make_shared<PlainVanillaPayoff>(Option::Call, strike);
            auto payoffP = ext::make_shared<PlainVanillaPayoff>(Option::Put,  strike);
            auto exercise = ext::make_shared<EuropeanExercise>(maturity);

            VanillaOption callOpt(payoffC, exercise);
            VanillaOption putOpt(payoffP, exercise);
            callOpt.setPricingEngine(engine);
            putOpt.setPricingEngine(engine);

            std::println(stderr,
                "[price_options] spot={:.2f} vol={:.4f} call={:.4f} put={:.4f}",
                spot, vol, callOpt.NPV(), putOpt.NPV());

            py::dict result;
            result["spot"]           = spot;
            result["volatility"]     = vol;
            result["risk_free_rate"] = risk_free_rate;
            result["maturity_days"]  = maturity_days;
            result["strike"]         = strike;
            result["call_price"]     = callOpt.NPV();
            result["put_price"]      = putOpt.NPV();
            result["call_delta"]     = callOpt.delta();
            result["put_delta"]      = putOpt.delta();
            result["gamma"]          = callOpt.gamma();
            result["theta"]          = callOpt.theta();
            result["vega"]           = callOpt.vega() / 100.0;
            result["rho"]            = callOpt.rho()  / 100.0;
            return result;
        },
        py::arg("table_like"),
        py::arg("risk_free_rate") = 0.05,
        py::arg("maturity_days")  = 30,
        "Price ATM European call+put from a 'close' column using QuantLib BS.\n\n"
        "Computes historical volatility from log returns, prices ATM options.\n"
        "Returns dict with spot, vol, prices, and Greeks (delta/gamma/theta/vega/rho).");
}
