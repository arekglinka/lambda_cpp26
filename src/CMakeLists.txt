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
# Override pybind11_strip before pybind11_add_module.  pybind11 3.0+
# unconditionally strips the .so in Release/MinSizeRel builds via a post-
# build /usr/bin/strip call — there's no PYBIND11_NO_STRIP option anymore.
# Containerfile's own `strip --strip-unneeded` handles production deploy,
# so the local-dev .so keeps DWARF for LLDB.
function(pybind11_strip)
endfunction()
pybind11_add_module(sum_columns
    MODULE
    sum_columns.cpp
)

# Our TU compiles at C++26; the dependency graph stays at c++17 (Conan profile).
target_compile_features(sum_columns PRIVATE cxx_std_26)

# Always emit DWARF debug info for our TU even in Release builds.  The deps
# stay optimized/stripped (multi-hour rebuild avoided); our .so grows by a few
# MB but Containerfile's `strip --strip-unneeded` removes it for production
# deploy.  Without this, C++ breakpoints set in sum_columns.cpp never hit
# when Python loads the .so under LLDB.
#
# -g must be on BOTH compile and link commands when -flto is active: GCC
# encapsulates debug info in .gnu.debuglto_* sections during compile, then
# the LTO link-time recompile emits final .debug_* sections — needs -g at
# link or LTO silently strips it.
target_compile_options(sum_columns PRIVATE -g)
target_link_options(sum_columns PRIVATE -g)

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
