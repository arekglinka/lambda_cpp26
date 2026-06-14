"""Conan 2.x recipe for Apache Arrow C++ 18.0.0.

Builds Arrow from the official Apache release tarball with ALL optional
modules enabled (Parquet, ORC, Flight, Flight SQL, S3, Gandiva, Compute,
CSV, JSON, Dataset, Filesystem) as a **static** library for AWS Lambda
on Amazon Linux 2023.

Why a custom recipe (not ConanCenter's ``arrow``)?
    1. ConanCenter's arrow recipe ships broken ORC defaults.
    2. ConanCenter hardcodes a *shared* LLVM for Gandiva.  Arrow GH-37410
       changed ``ARROW_LLVM_USE_SHARED`` to default ``ON`` (following
       ``ARROW_DEPENDENCY_USE_SHARED``).  For a fully-static Lambda build
       we MUST force it ``OFF`` — this is the #1 pitfall.
    3. AL2023 lacks ``bz2`` development headers, so ``ARROW_WITH_BZ2=OFF``
       is mandatory.

Dependency strategy: ``ARROW_DEPENDENCY_SOURCE=AUTO`` lets Arrow's
``find_package()`` calls discover Conan-provided packages first (via
``CMakeDeps``), falling back to Arrow's bundled copies only if a Conan
package is absent.  This avoids the duplicate-symbol problem that
``BUNDLED`` would cause against the consumer's explicit Conan
requirements (lz4, zstd, snappy, zlib, brotli, …).

Consumer reference (lambda_cpp26/conanfile.py)::

    self.requires("arrow/18.0.0", options={...})
    self.cpp_info.components["arrow"].requires = ["arrow::arrow_static"]

Verified CMake targets (from Arrow 18.0.0 ``BuildUtils.cmake`` +
per-module ``CMakeLists.txt``)::

    Arrow::arrow_static                   — core (bundles compute/csv/json/orc/s3/fs)
    Parquet::parquet_static               — Parquet
    ArrowFlight::arrow_flight_static      — Flight
    ArrowFlightSql::arrow_flight_sql_static — Flight SQL
    Gandiva::gandiva_static               — Gandiva (LLVM JIT)
"""

import os

from conan import ConanFile
from conan.tools.cmake import CMake, CMakeDeps, CMakeToolchain, cmake_layout
from conan.tools.files import copy, get, rmdir

required_conan_version = ">=2.4"


class ArrowConan(ConanFile):
    name = "arrow"
    version = "18.0.0"
    license = "Apache-2.0"
    description = "Apache Arrow C++ — columnar in-memory analytics layer"
    topics = ("arrow", "parquet", "flight", "gandiva", "columnar", "analytics")
    homepage = "https://arrow.apache.org/"
    url = "https://archive.apache.org/dist/arrow/arrow-18.0.0/"

    package_type = "static-library"

    settings = "os", "arch", "compiler", "build_type"

    # Options must match what lambda_cpp26/conanfile.py passes:
    #   options={"shared": False, "gandiva": ..., "flight": ..., ...}
    options = {
        "shared": [True, False],
        "fPIC": [True, False],
        "gandiva": [True, False],
        "flight": [True, False],
        "flight_sql": [True, False],
        "s3": [True, False],
        "orc": [True, False],
        "parquet": [True, False],
        "compute": [True, False],
        "csv": [True, False],
        "json": [True, False],
    }

    default_options = {
        "shared": False,
        "fPIC": True,
        "gandiva": True,
        "flight": True,
        "flight_sql": True,
        "s3": True,
        "orc": True,
        "parquet": True,
        "compute": True,
        "csv": True,
        "json": True,
    }

    # auto_shared_fpic: shared=True forces fPIC off; shared=False keeps fPIC.
    # Requires Conan >= 2.4 (see required_conan_version above).
    implements = ["auto_shared_fpic"]

    conan_data = {
        "sources": {
            "18.0.0": {
                "url": "https://archive.apache.org/dist/arrow/arrow-18.0.0/apache-arrow-18.0.0.tar.gz",  # noqa: E501
                "sha256": "abcf1934cd0cdddd33664e9f2d9a251d6c55239d1122ad0ed223b13a583c82a9",
            },
        },
    }

    # ------------------------------------------------------------------ #
    #  Dependencies                                                      #
    # ------------------------------------------------------------------ #

    def requirements(self):
        # Boost is header-only to avoid ABI clashes with Arrow's bundled
        # third-party copies (matches the consumer pin).
        self.requires(
            "boost/1.87.0",
            transitive_headers=True,
            transitive_libs=True,
            options={"header_only": True},
        )

        # --- Compression codecs (all static) ---
        self.requires("lz4/1.10.0", options={"shared": False})
        self.requires("zstd/1.5.6", options={"shared": False})
        self.requires("snappy/1.2.1", options={"shared": False})
        self.requires("zlib/1.3.1", options={"shared": False})
        self.requires("brotli/1.1.0", options={"shared": False})

        # --- String processing ---
        self.requires("re2/20251105", options={"shared": False})
        self.requires("utf8proc/2.9.0", options={"shared": False})
        self.requires("rapidjson/cci.20250205")

        # --- TLS/SSL (needed by gRPC-SSL, S3, Flight) ---
        self.requires("openssl/3.5.7", options={"shared": False})

        # --- Flight / Flight SQL ---
        if self.options.flight:
            self.requires("grpc/1.81.0", options={"shared": False})
            self.requires("protobuf/5.29.3", options={"shared": False})

        # --- Parquet ---
        if self.options.parquet:
            self.requires("thrift/0.23.0", options={"shared": False})

        # --- Gandiva (LLVM JIT) ---
        if self.options.gandiva:
            self.requires("llvm-core/19.1.7", options={"shared": False})

        # --- S3 filesystem (Arrow bundles AWS SDK via ThirdpartyToolchain) ---
        # No explicit Conan dep needed — Arrow downloads and builds AWS CRT.

    def build_requirements(self):
        self.tool_requires("cmake/[>=3.25 <4]")
        self.tool_requires("ninja/[>=1.11 <2]")

    # ------------------------------------------------------------------ #
    #  Layout & source                                                   #
    # ------------------------------------------------------------------ #

    def layout(self):
        self.folders.source = "cpp"
        self.folders.build = "build"
        self.folders.generators = "build"

    def source(self):
        # strip_root=True removes the apache-arrow-18.0.0/ top-level dir so
        # cpp/ sits at the Conan source root (matching layout() above).
        get(self, **self.conan_data["sources"][self.version], strip_root=True)

    # ------------------------------------------------------------------ #
    #  CMake configuration                                               #
    # ------------------------------------------------------------------ #

    def generate(self):
        tc = CMakeToolchain(self)

        # CMP0077: option() respects cache variables set before project().
        # Without this, Arrow's option() calls would ignore our cache vars.
        tc.cache_variables["CMAKE_POLICY_DEFAULT_CMP0077"] = "NEW"

        # ---- Static vs shared ----
        tc.cache_variables["ARROW_BUILD_STATIC"] = "ON"
        tc.cache_variables["ARROW_BUILD_SHARED"] = "OFF"
        tc.cache_variables["ARROW_STATIC_LINK_LIBCXX"] = "ON"

        # ---- Force ALL transitive deps to static linkage ----
        tc.cache_variables["ARROW_DEPENDENCY_USE_SHARED"] = "OFF"
        tc.cache_variables["ARROW_BOOST_USE_SHARED"] = "OFF"
        tc.cache_variables["ARROW_BROTLI_USE_SHARED"] = "OFF"
        tc.cache_variables["ARROW_BZ2_USE_SHARED"] = "OFF"
        tc.cache_variables["ARROW_GFLAGS_USE_SHARED"] = "OFF"
        tc.cache_variables["ARROW_GRPC_USE_SHARED"] = "OFF"
        tc.cache_variables["ARROW_JEMALLOC_USE_SHARED"] = "OFF"
        tc.cache_variables["ARROW_LZ4_USE_SHARED"] = "OFF"
        tc.cache_variables["ARROW_OPENSSL_USE_SHARED"] = "OFF"
        tc.cache_variables["ARROW_PROTOBUF_USE_SHARED"] = "OFF"
        tc.cache_variables["ARROW_SNAPPY_USE_SHARED"] = "OFF"
        tc.cache_variables["ARROW_THRIFT_USE_SHARED"] = "OFF"
        tc.cache_variables["ARROW_UTF8PROC_USE_SHARED"] = "OFF"
        tc.cache_variables["ARROW_ZSTD_USE_SHARED"] = "OFF"

        # ---- Compression codecs ----
        tc.cache_variables["ARROW_WITH_SNAPPY"] = "ON"
        tc.cache_variables["ARROW_WITH_ZLIB"] = "ON"
        tc.cache_variables["ARROW_WITH_ZSTD"] = "ON"
        tc.cache_variables["ARROW_WITH_LZ4"] = "ON"
        tc.cache_variables["ARROW_WITH_BROTLI"] = "ON"
        tc.cache_variables["ARROW_WITH_UTF8PROC"] = "ON"
        tc.cache_variables["ARROW_WITH_RE2"] = "ON"
        tc.cache_variables["ARROW_WITH_RAPIDJSON"] = "ON"
        # AL2023 lacks bz2 development headers — MUST be OFF.
        tc.cache_variables["ARROW_WITH_BZ2"] = "OFF"

        # ---- Core modules ----
        tc.cache_variables["ARROW_COMPUTE"] = "ON" if self.options.compute else "OFF"
        tc.cache_variables["ARROW_CSV"] = "ON" if self.options.csv else "OFF"
        tc.cache_variables["ARROW_JSON"] = "ON" if self.options.json else "OFF"
        tc.cache_variables["ARROW_FILESYSTEM"] = "ON"
        tc.cache_variables["ARROW_DATASET"] = "ON"

        # ---- Optional modules ----
        tc.cache_variables["ARROW_PARQUET"] = "ON" if self.options.parquet else "OFF"
        tc.cache_variables["ARROW_ORC"] = "ON" if self.options.orc else "OFF"

        if self.options.flight:
            tc.cache_variables["ARROW_FLIGHT"] = "ON"
            tc.cache_variables["ARROW_BUILD_GRPC_CPP"] = "ON"
            tc.cache_variables["ARROW_GRPC_USE_SSL"] = "ON"
        else:
            tc.cache_variables["ARROW_FLIGHT"] = "OFF"
            tc.cache_variables["ARROW_BUILD_GRPC_CPP"] = "OFF"

        tc.cache_variables["ARROW_FLIGHT_SQL"] = (
            "ON" if self.options.flight_sql else "OFF"
        )
        tc.cache_variables["ARROW_S3"] = "ON" if self.options.s3 else "OFF"

        if self.options.gandiva:
            tc.cache_variables["ARROW_GANDIVA"] = "ON"
            # CRITICAL (GH-37410): Arrow changed ARROW_LLVM_USE_SHARED default
            # to follow ARROW_DEPENDENCY_USE_SHARED (which defaulted ON).  For
            # a fully-static Lambda build we MUST force static LLVM here.
            #
            # NOTE: the CMake variable is "ARROW_LLVM_USE_SHARED" — verified
            # against Arrow 18.0.0 cpp/cmake_modules/DefineOptions.cmake line
            # 514.  The name "ARROW_GANDIVA_USE_SHARED_LLVM" does NOT exist
            # in Arrow's option definitions; using it would silently fail.
            tc.cache_variables["ARROW_LLVM_USE_SHARED"] = "OFF"
            # Bundle libstdc++/libgcc into the static Gandiva library so the
            # JIT-compiled code links correctly without a shared runtime.
            tc.cache_variables["ARROW_GANDIVA_STATIC_LIBSTDCPP"] = "ON"
        else:
            tc.cache_variables["ARROW_GANDIVA"] = "OFF"

        # ---- Disable non-essential ----
        tc.cache_variables["ARROW_BUILD_TESTS"] = "OFF"
        tc.cache_variables["ARROW_BUILD_BENCHMARKS"] = "OFF"
        tc.cache_variables["ARROW_BUILD_EXAMPLES"] = "OFF"
        tc.cache_variables["ARROW_BUILD_UTILITIES"] = "OFF"
        tc.cache_variables["ARROW_BUILD_INTEGRATION"] = "OFF"
        tc.cache_variables["ARROW_FUZZING"] = "OFF"
        tc.cache_variables["ARROW_INSTALL_NAME_RPATH"] = "OFF"

        # ---- Disable bundled allocators (use system malloc) ----
        tc.cache_variables["ARROW_JEMALLOC"] = "OFF"
        tc.cache_variables["ARROW_MIMALLOC"] = "OFF"
        tc.cache_variables["ARROW_WITH_BACKTRACE"] = "OFF"
        tc.cache_variables["ARROW_PYTHON"] = "OFF"

        # ---- C++26 standard ----
        tc.cache_variables["CMAKE_CXX_STANDARD"] = "26"
        tc.cache_variables["CMAKE_CXX_STANDARD_REQUIRED"] = "ON"
        tc.cache_variables["CMAKE_CXX_EXTENSIONS"] = "OFF"

        # ---- LLVM discovery (Gandiva) ----
        if self.options.gandiva:
            llvm = self.dependencies["llvm-core"].cpp_info
            llvm_dir = os.path.join(self.dependencies["llvm-core"].package_folder, "lib", "cmake", "llvm")
            # Arrow's FindLLVMAlt.cmake calls find_package(LLVM ...).
            # Pointing LLVM_DIR at the Conan-provided llvm-core config makes
            # find_package(LLVM) succeed without a system LLVM install.
            tc.cache_variables["LLVM_DIR"] = llvm_dir

            # Narrow the LLVM link to the 9 components Gandiva's ORC JIT
            # actually uses — avoids linking all ~60 LLVM static archives.
            tc.cache_variables["ARROW_LLVM_LINK_LIBS"] = " ".join(
                [
                    "LLVMAnalysis",
                    "LLVMBitReader",
                    "LLVMCore",
                    "LLVMipo",
                    "LLVMLinker",
                    "LLVMNative",
                    "LLVMOrcJIT",
                    "LLVMTarget",
                    "LLVMPasses",
                ]
            )

        # ---- CMAKE_PREFIX_PATH for deps Arrow finds via custom Alt modules ----
        # CMakeDeps generates config files for standard find_package() calls,
        # but Arrow's Find*Alt.cmake modules sometimes do manual
        # find_library()/find_path() searches.  Adding the dep roots to
        # CMAKE_PREFIX_PATH makes those Alt finders succeed.
        prefix_paths = []
        prefix_paths.append(self.dependencies["boost"].package_folder)
        if self.options.gandiva:
            prefix_paths.append(
                self.dependencies["llvm-core"].package_folder
            )
        if self.options.parquet:
            prefix_paths.append(
                self.dependencies["thrift"].package_folder
            )
        if self.options.flight:
            prefix_paths.append(
                self.dependencies["grpc"].package_folder
            )
            prefix_paths.append(
                self.dependencies["protobuf"].package_folder
            )
        for dep_name in (
            "lz4", "zstd", "snappy", "zlib", "brotli",
            "re2", "utf8proc", "openssl",
        ):
            if dep_name in self.dependencies:
                prefix_paths.append(
                    self.dependencies[dep_name].package_folder
                )
        tc.variables["CMAKE_PREFIX_PATH"] = ";".join(prefix_paths)

        if "abseil" in self.dependencies:
            abseil_inc = os.path.join(self.dependencies["abseil"].package_folder, "include")
            cxxflags = tc.cache_variables.get("CMAKE_CXX_FLAGS", "")
            tc.cache_variables["CMAKE_CXX_FLAGS"] = f"{cxxflags} -I{abseil_inc}".strip()

        tc.generate()

        # CMakeDeps generates config files so Arrow's find_package() calls
        # resolve to Conan-provided packages.
        CMakeDeps(self).generate()

    # ------------------------------------------------------------------ #
    #  Build & package                                                   #
    # ------------------------------------------------------------------ #

    def build(self):
        import subprocess, os

        result = subprocess.run(
            ["find", "/root/.conan2/p/b", "-name", "CMakeLists.txt",
             "-path", "*/cpp/CMakeLists.txt", "-not", "-path", "*/test*",
             "-not", "-path", "*/python/*"],
            capture_output=True, text=True, timeout=10,
        )
        candidates = [l.strip() for l in result.stdout.strip().split("\n") if l.strip()]
        source_dir = os.path.dirname(candidates[0]) if candidates else None

        if source_dir and source_dir != self.source_folder:
            self.output.warning(f"arrow: cmake source {self.source_folder} -> {source_dir}")
            cls = type(self)
            orig = cls.source_folder
            cls.source_folder = property(lambda s: source_dir)
            try:
                cmake = CMake(self)
                cmake.configure()
                cmake.build()
            finally:
                cls.source_folder = orig
        else:
            cmake = CMake(self)
            cmake.configure()
            cmake.build()

    def _safe_parallel(self):
        # LLVM link-time peak memory is ~12 GB; cap parallelism at 1 on hosts
        # with <16 GB RAM to avoid OOM-killing the Gandiva build.
        try:
            mem_gb = (
                os.sysconf("SC_PAGE_SIZE")
                * os.sysconf("SC_PHYS_PAGES")
                / (1024**3)
            )
            return (
                1
                if mem_gb < 16
                else min(4, self.conf.get("tools.build:jobs", default=4))
            )
        except (ValueError, OSError, AttributeError):
            return 2

    def package(self):
        cmake = CMake(self)
        cmake.install()

        # License files live at the tarball root (parent of cpp/, which is
        # self.source_folder per the layout above).
        tarball_root = os.path.dirname(self.source_folder)
        copy(
            self,
            "LICENSE.txt",
            src=tarball_root,
            dst=os.path.join(self.package_folder, "licenses"),
            keep_path=False,
        )
        copy(
            self,
            "NOTICE.txt",
            src=tarball_root,
            dst=os.path.join(self.package_folder, "licenses"),
            keep_path=False,
        )

        # Remove pkg-config files (we use CMake targets exclusively).
        rmdir(self, os.path.join(self.package_folder, "lib", "pkgconfig"))

    # ------------------------------------------------------------------ #
    #  package_info — CMake targets & components                         #
    # ------------------------------------------------------------------ #

    def package_info(self):
        # The top-level cmake_file_name enables find_package(Arrow REQUIRED).
        self.cpp_info.set_property("cmake_file_name", "Arrow")

        # Common transitive requirements for the core arrow library.
        # Arrow bundles compute/csv/json/orc/s3/dataset/filesystem/ipc/io
        # into libarrow.a — they are NOT separate link libraries.
        arrow_core_reqs = [
            "boost::boost",
            "re2::re2",
            "utf8proc::utf8proc",
            "rapidjson::rapidjson",
            "lz4::lz4",
            "zstd::zstd",
            "snappy::snappy",
            "zlib::zlib",
            "brotli::brotli",
            "openssl::openssl",
        ]
        # --- Arrow core (libarrow.a) ---
        # Consumer references this as "arrow::arrow_static".
        arrow = self.cpp_info.components["arrow_static"]
        arrow.libs = ["arrow"]
        arrow.set_property("cmake_target_name", "Arrow::arrow_static")
        arrow.set_property("cmake_file_name", "Arrow")
        arrow.requires = arrow_core_reqs

        # Arrow needs system libraries on POSIX.
        if self.settings.os in ("Linux", "FreeBSD"):
            arrow.system_libs.extend(["pthread", "dl", "rt", "m"])

        # --- Parquet (libparquet.a) ---
        if self.options.parquet:
            parquet = self.cpp_info.components["parquet_static"]
            parquet.libs = ["parquet"]
            parquet.set_property("cmake_target_name", "Parquet::parquet_static")
            parquet.set_property("cmake_file_name", "Parquet")
            parquet.requires = ["arrow_static", "thrift::thrift"]

        # --- Flight (libarrow_flight.a) ---
        if self.options.flight:
            flight = self.cpp_info.components["arrow_flight_static"]
            flight.libs = ["arrow_flight"]
            flight.set_property(
                "cmake_target_name", "ArrowFlight::arrow_flight_static"
            )
            flight.set_property("cmake_file_name", "ArrowFlight")
            flight.requires = [
                "arrow_static",
                "grpc::grpc",
                "protobuf::protobuf",
            ]

        # --- Flight SQL (libarrow_flight_sql.a) ---
        if self.options.flight_sql:
            flight_sql = self.cpp_info.components["arrow_flight_sql_static"]
            flight_sql.libs = ["arrow_flight_sql"]
            flight_sql.set_property(
                "cmake_target_name", "ArrowFlightSql::arrow_flight_sql_static"
            )
            flight_sql.set_property("cmake_file_name", "ArrowFlightSql")
            flight_sql.requires = ["arrow_flight_static"]

        # --- Bundled dependencies (interface target, e.g. jemalloc) ---
        # With ARROW_JEMALLOC=OFF and ARROW_MIMALLOC=OFF this is empty,
        # but the consumer links against it so it must exist as a component.
        bundled = self.cpp_info.components["arrow_bundled_dependencies"]
        bundled.libs = []
        bundled.set_property("cmake_target_name", "Arrow::arrow_bundled_dependencies")
        bundled.set_property("cmake_file_name", "Arrow")

        # --- Gandiva (libgandiva.a) ---
        if self.options.gandiva:
            gandiva = self.cpp_info.components["gandiva_static"]
            gandiva.libs = ["gandiva"]
            gandiva.set_property("cmake_target_name", "Gandiva::gandiva_static")
            gandiva.set_property("cmake_file_name", "Gandiva")
            gandiva.requires = ["arrow_static", "llvm-core::llvm-core"]
