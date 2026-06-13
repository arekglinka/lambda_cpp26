/// @file handler.cpp
/// Sample AWS Lambda handler demonstrating lambda_cpp26 library usage.
///
/// This handler uses the aws-lambda-cpp runtime library (header-only, Conan:
/// aws-lambda-runtime/0.2.6). The bootstrap shell script invokes this binary
/// via the Lambda Runtime Interface Emulator (RIE) for local testing or the
/// Lambda Runtime API when deployed.

#include <lambda_cpp26/api.hpp>

#include <aws/lambda-runtime/runtime-api.h>

#include <cstdlib>
#include <iostream>
#include <memory>
#include <stdexcept>

using namespace aws::lambda_runtime;

/// Global engine — initialized once, reused across warm invocations.
static std::unique_ptr<lambda_cpp26::Engine> g_engine;

/// Initialize the engine on first invocation (persists across warm starts).
static void ensure_initialized() {
    if (!g_engine) {
        g_engine = std::make_unique<lambda_cpp26::Engine>();
        g_engine->initialize();
    }
}

static invocation_response my_handler(invocation_request const& request) {
    try {
        ensure_initialized();

        auto result = g_engine->process(request.payload);
        return invocation_response::success(result, "application/json");

    } catch (const std::exception& e) {
        std::cerr << "[handler] ERROR: " << e.what() << std::endl;
        return invocation_response::failure(e.what(), "application/json");
    }
}

int main(int argc, char** argv) {
    // When running inside Lambda, run_handler() manages the Runtime API loop.
    // When running locally with RIE, same loop connects to localhost:9000.
    run_handler(my_handler);
    return 0;
}
