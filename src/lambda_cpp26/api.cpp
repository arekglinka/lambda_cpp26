#include "api.hpp"

#include <arrow/api.h>
#include <arrow/compute/api.h>
#include <ql/quantlib.hpp>

#include <mutex>
#include <stdexcept>

namespace lambda_cpp26 {

class Engine::Impl {
public:
    bool initialized = false;
    std::mutex mutex;
};

Engine::Engine() : impl_(std::make_unique<Impl>()) {}
Engine::~Engine() = default;

Engine::Engine(Engine&& other) noexcept = default;
Engine& operator=(Engine&& other) noexcept = default;

void Engine::initialize(const std::string& /*config_path*/) {
    std::lock_guard<std::mutex> lock(impl_->mutex);
    if (impl_->initialized) {
        return;
    }

    // Verify Arrow is linked and functional
    auto schema = arrow::schema({arrow::field("col", arrow::int64())});
    auto builder = arrow::Int64Builder();
    (void)builder.Append(42);
    std::shared_ptr<arrow::Array> array;
    auto status = builder.Finish(&array);
    if (!status.ok()) {
        throw std::runtime_error("Arrow initialization failed: " + status.ToString());
    }

    // Verify QuantLib is linked and functional
    // QuantLib::Calendar cal = QuantLib::TARGET();
    // (void)cal;

    impl_->initialized = true;
}

std::string Engine::process(const std::string& json_input) {
    if (!impl_->initialized) {
        throw std::runtime_error("Engine not initialized — call initialize() first");
    }

    // TODO: Replace with actual processing logic
    return R"({"status":"ok","version":")" + version() + R"(","input_length":)"
        + std::to_string(json_input.size()) + "}";
}

std::string Engine::version() const {
    return "0.1.0-dev";
}

bool Engine::is_initialized() const {
    return impl_->initialized;
}

} // namespace lambda_cpp26
