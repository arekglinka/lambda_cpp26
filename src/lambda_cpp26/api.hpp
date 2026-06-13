#pragma once

/// @file api.hpp
/// Public API for the lambda_cpp26 static library.
///
/// This is a boilerplate stub — replace with your actual library interface.
/// The library is designed to be statically linked into an AWS Lambda handler.

#include <string>
#include <memory>
#include <functional>

namespace lambda_cpp26 {

/// Core engine — initializes heavy dependencies (Arrow, QuantLib) and
/// provides a JSON-based process() interface suitable for Lambda invocation.
class Engine {
public:
    Engine();
    ~Engine();

    Engine(const Engine&) = delete;
    Engine& operator=(const Engine&) = delete;
    Engine(Engine&&) noexcept;
    Engine& operator=(Engine&&) noexcept;

    /// Initialize dependencies. Call once before process().
    /// @param config_path Optional JSON config (empty = defaults).
    void initialize(const std::string& config_path = "");

    /// Process a JSON payload and return a JSON response.
    /// Thread-safe: can be called concurrently after initialize().
    /// @param json_input JSON string from Lambda event.
    /// @return JSON string response.
    std::string process(const std::string& json_input);

    /// Library version string.
    std::string version() const;

    /// Check if engine has been initialized.
    bool is_initialized() const;
};

} // namespace lambda_cpp26
