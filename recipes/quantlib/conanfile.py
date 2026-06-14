"""Conan 2.x recipe for QuantLib 1.38.

Builds QuantLib from the official GitHub release tarball as a **static**
library for AWS Lambda on Amazon Linux 2023.

Why a custom recipe (not ConanCenter's ``quantlib``)?
    ConanCenter is stuck at 1.30; current stable is 1.38.  This recipe
    also enables QL_USE_STD_CLASSES (std::shared_ptr/optional/any instead
    of Boost's), which shrinks the Lambda cold-start image by eliminating
    compiled Boost library dependencies.

Consumer reference (lambda_cpp26/conanfile.py)::

    self.requires("quantlib/1.38", options={"shared": False})
    self.cpp_info.components["quantlib"].requires = ["quantlib::quantlib"]

Verified CMake targets (from QuantLib-1.38 ql/CMakeLists.txt)::

    add_library(ql_library ... EXPORT_NAME QuantLib OUTPUT_NAME QuantLib)
    install(EXPORT QuantLibTargets ... NAMESPACE QuantLib::)

    → find_package(QuantLib) → QuantLib::QuantLib
    → libQuantLib.a
"""

import os

from conan import ConanFile
from conan.tools.cmake import CMake, CMakeDeps, CMakeToolchain, cmake_layout
from conan.tools.files import copy, get

required_conan_version = ">=2.4"


class QuantLibConan(ConanFile):
    name = "quantlib"
    version = "1.38"
    license = "BSD-3-Clause"
    description = "QuantLib — open-source library for quantitative finance"
    topics = ("quantlib", "finance", "quantitative-finance")
    homepage = "https://www.quantlib.org/"
    url = "https://github.com/lballabio/QuantLib"

    package_type = "static-library"
    settings = "os", "arch", "compiler", "build_type"

    options = {
        "shared": [True, False],
        "fPIC": [True, False],
    }
    default_options = {
        "shared": False,
        "fPIC": True,
    }

    implements = ["auto_shared_fpic"]

    conan_data = {
        "sources": {
            "1.38": {
                "url": "https://github.com/lballabio/QuantLib/releases/download/v1.38/QuantLib-1.38.tar.gz",  # noqa: E501
                "sha256": "7280ffd0b81901f8a9eb43bb4229e4de78384fc8bb2d9dcfb5aa8cf8b257b439",
            },
        },
    }

    # ------------------------------------------------------------------ #
    #  Dependencies                                                      #
    # ------------------------------------------------------------------ #

    def requirements(self):
        # QL_USE_STD_CLASSES (set in generate()) replaces boost::shared_ptr,
        # boost::optional, boost::any with std equivalents, so header-only
        # Boost is sufficient — no compiled Boost libraries needed.
        self.requires(
            "boost/1.87.0",
            transitive_headers=True,
            transitive_libs=True,
            options={"header_only": True},
        )

    def build_requirements(self):
        self.tool_requires("cmake/[>=3.25 <4]")
        self.tool_requires("ninja/[>=1.11 <2]")

    # ------------------------------------------------------------------ #
    #  Layout & source                                                   #
    # ------------------------------------------------------------------ #

    def layout(self):
        cmake_layout(self, src_folder=".")

    def source(self):
        get(self, **self.conan_data["sources"][self.version], strip_root=True)

    # ------------------------------------------------------------------ #
    #  CMake configuration                                               #
    # ------------------------------------------------------------------ #

    def generate(self):
        tc = CMakeToolchain(self)

        # CMP0077: option() respects cache variables set before project().
        tc.cache_variables["CMAKE_POLICY_DEFAULT_CMP0077"] = "NEW"

        # ---- Static library ----
        tc.cache_variables["BUILD_SHARED_LIBS"] = "OFF"

        # ---- C++26 standard ----
        tc.cache_variables["CMAKE_CXX_STANDARD"] = "26"
        tc.cache_variables["CMAKE_CXX_STANDARD_REQUIRED"] = "ON"
        tc.cache_variables["CMAKE_CXX_EXTENSIONS"] = "OFF"

        # ---- Use std:: classes instead of Boost equivalents ----
        # Eliminates the need for compiled Boost libs; header-only Boost
        # suffices for the few remaining fallback paths.
        tc.cache_variables["QL_USE_STD_CLASSES"] = "ON"
        tc.cache_variables["QL_USE_STD_ANY"] = "ON"
        tc.cache_variables["QL_USE_STD_OPTIONAL"] = "ON"
        tc.cache_variables["QL_USE_STD_SHARED_PTR"] = "ON"

        # ---- Disable non-essential targets ----
        tc.cache_variables["QL_BUILD_EXAMPLES"] = "OFF"
        tc.cache_variables["QL_BUILD_TEST_SUITE"] = "OFF"
        tc.cache_variables["QL_BUILD_FUZZ_TEST_SUITE"] = "OFF"
        tc.cache_variables["QL_INSTALL_BENCHMARK"] = "OFF"
        tc.cache_variables["QL_INSTALL_EXAMPLES"] = "OFF"
        tc.cache_variables["QL_INSTALL_TEST_SUITE"] = "OFF"

        # ---- Thread safety (Lambda cold-start safety) ----
        tc.cache_variables["QL_ENABLE_SESSIONS"] = "ON"
        tc.cache_variables["QL_ENABLE_THREAD_SAFE_OBSERVER_PATTERN"] = "ON"

        # ---- Disable diagnostic bloat in production ----
        tc.cache_variables["QL_ENABLE_TRACING"] = "OFF"
        tc.cache_variables["QL_ERROR_FUNCTIONS"] = "OFF"
        tc.cache_variables["QL_ERROR_LINES"] = "OFF"
        tc.cache_variables["QL_EXTRA_SAFETY_CHECKS"] = "OFF"
        tc.cache_variables["QL_ENABLE_OPENMP"] = "OFF"

        # ---- Section-level GC for selective linking ----
        # QuantLib compiles all 972 .cpp files into a single archive (~1.2 GB
        # debug, ~25-35 MB stripped).  Dead-code elimination at consumer link
        # time is the only effective size filter, so we emit per-function
        # sections here.
        tc.variables["CMAKE_CXX_FLAGS"] = " ".join(
            filter(
                None,
                [
                    os.environ.get("CMAKE_CXX_FLAGS", ""),
                    "-ffunction-sections",
                    "-fdata-sections",
                ],
            )
        )

        tc.generate()

        CMakeDeps(self).generate()

    # ------------------------------------------------------------------ #
    #  Build & package                                                   #
    # ------------------------------------------------------------------ #

    def build(self):
        cmake = CMake(self)
        cmake.configure()
        cmake.build()

    def package(self):
        cmake = CMake(self)
        cmake.install()

        copy(
            self,
            "LICENSE.TXT",
            src=self.source_folder,
            dst=os.path.join(self.package_folder, "licenses"),
            keep_path=False,
        )

    # ------------------------------------------------------------------ #
    #  package_info                                                      #
    # ------------------------------------------------------------------ #

    def package_info(self):
        self.cpp_info.set_property("cmake_file_name", "QuantLib")
        self.cpp_info.set_property("cmake_target_name", "QuantLib::QuantLib")

        # Component name "quantlib" (lowercase) so the consumer can reference
        # it as "quantlib::quantlib" in its own components.
        ql = self.cpp_info.components["quantlib"]
        ql.libs = ["QuantLib"]
        ql.requires = ["boost::boost"]

        if self.settings.os in ("Linux", "FreeBSD"):
            ql.system_libs.append("pthread")
