cmake_minimum_required(VERSION 3.28)
project(lambda_cpp26 LANGUAGES CXX)

# Emit compile_commands.json so clangd / vscode-cpptools can resolve includes
# (pybind11, Arrow, GCC 16 stdlib) for IntelliSense.  Without this, editors
# show false-positive errors on every #include they can't see.
set(CMAKE_EXPORT_COMPILE_COMMANDS ON)

# --- Python + pybind11 ---
# Development.Module (not Development) links libpython DYNAMICALLY — required
# for a CPython extension module (the PyInit_ entry point needs the host
# interpreter's libpython at runtime).
find_package(Python REQUIRED COMPONENTS Interpreter Development.Module)

# pybind11 is pip-installed — find its CMake dir dynamically.
execute_process(
    COMMAND "${Python_EXECUTABLE}" -c "import pybind11; print(pybind11.get_cmake_dir())"
    OUTPUT_VARIABLE PYBIND11_CMAKE_DIR
    OUTPUT_STRIP_TRAILING_WHITESPACE
    RESULT_VARIABLE _pybind11_result
)
if(_pybind11_result EQUAL 0 AND PYBIND11_CMAKE_DIR)
    list(APPEND CMAKE_PREFIX_PATH "${PYBIND11_CMAKE_DIR}")
endif()
find_package(pybind11 CONFIG REQUIRED)

# --- Arrow (C Data Interface + compute) ---
find_package(Arrow REQUIRED CONFIG)
find_package(QuantLib REQUIRED CONFIG)

# --- pybind11 extension module ---
pybind11_add_module(sum_columns
    MODULE
    sum_columns.cpp
)

# Our TU compiles at C++26; the dependency graph stays at c++17 (Conan profile).
target_compile_features(sum_columns PRIVATE cxx_std_26)

target_link_libraries(sum_columns PRIVATE
    Python::Module
    pybind11::module
    Arrow::arrow_static
    Arrow::arrow_bundled_dependencies
    QuantLib::QuantLib
)

# Bundle GCC 16's libstdc++/libgcc INTO the .so so it runs on the Lambda
# runtime's older libstdc++ without GLIBCXX errors.  --gc-sections discards
# unreferenced static-archive symbols (Arrow + QuantLib are large).
target_link_options(sum_columns PRIVATE
    -static-libgcc
    -static-libstdc++
    -Wl,--gc-sections
)

# Output: sum_columns.cpython-312-x86_64-linux-gnu.so (no "lib" prefix).
set_target_properties(sum_columns PROPERTIES
    PREFIX ""
    OUTPUT_NAME sum_columns
)
