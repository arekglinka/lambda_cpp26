"""Conan recipe for lambda_cpp26 — a static library bundling Apache Arrow C++
(all modules: Parquet, ORC, Flight, Flight SQL, S3, Gandiva, Compute, CSV, JSON)
and QuantLib, targeted at AWS Lambda on Amazon Linux 2023.

Build flow (inside the Podman/AL2023 builder):
    conan install .         --build=missing
    conan build .           (or `cmake --build` via the generated toolchain)

Arrow and QuantLib are built from custom recipes under `recipes/` because
ConanCenter's `arrow` recipe ships broken ORC defaults and hardcodes a shared
LLVM, and ConanCenter's `quantlib` recipe is stuck at 1.30 (current stable
is 1.38). All other transitive dependencies are pulled from ConanCenter so we
get version deduplication and a single ABI-consistent dependency graph.
"""

from conan import ConanFile
from conan.tools.cmake import CMakeToolchain, CMake, cmake_layout, CMakeDeps

required_conan_version = ">=2.4"


class LambdaCpp26ConanFile(ConanFile):
    name = "lambda_cpp26"
    version = "0.1.0"
    license = "MIT"
    description = "C++26 static library for AWS Lambda — Arrow C++ + QuantLib"
    topics = ("aws-lambda", "cpp26", "arrow", "quantlib", "al2023")
    author = "lambda_cpp26 contributors"
    homepage = "https://github.com/example/lambda_cpp26"
    url = homepage

    package_type = "static-library"
    settings = "os", "compiler", "build_type", "arch"
    options = {
        "shared": [True, False],
        "fPIC": [True, False],
        "with_gandiva": [True, False],
        "with_flight": [True, False],
        "with_s3": [True, False],
        "with_orc": [True, False],
    }
    default_options = {
        "shared": False,
        "fPIC": True,
        "with_gandiva": True,
        "with_flight": True,
        "with_s3": True,
        "with_orc": True,
    }

    # auto_shared_fpic: shared=True forces fPIC off; shared=False keeps fPIC.
    # Requires Conan >= 2.4 (see required_conan_version above).
    implements = ["auto_shared_fpic"]

    def requirements(self):
        # Boost is header-only for both Arrow and QuantLib. Forcing header_only
        # here prevents ConanCenter's compiled Boost libs from clashing with
        # Arrow's bundled third-party copies.
        self.requires(
            "boost/1.87.0",
            transitive_headers=True,
            transitive_libs=True,
            options={"header_only": True},
        )

        self.requires("grpc/1.81.0", options={"shared": False})
        self.requires("protobuf/5.29.3", options={"shared": False})
        self.requires("thrift/0.23.0", options={"shared": False})
        self.requires("re2/20251105", options={"shared": False})
        self.requires("utf8proc/2.9.0", options={"shared": False})
        self.requires("rapidjson/cci.20250205")

        self.requires("lz4/1.10.0", options={"shared": False})
        self.requires("zstd/1.5.6", options={"shared": False})
        self.requires("snappy/1.2.1", options={"shared": False})
        self.requires("zlib/1.3.1", options={"shared": False})
        self.requires("brotli/1.1.0", options={"shared": False})

        self.requires("openssl/3.5.7", options={"shared": False})

        self.requires(
            "arrow/18.0.0",
            options={
                "shared": False,
                "gandiva": self.options.with_gandiva,
                "flight": self.options.with_flight,
                "flight_sql": self.options.with_flight,
                "s3": self.options.with_s3,
                "orc": self.options.with_orc,
                "parquet": True,
                "compute": True,
                "csv": True,
                "json": True,
            },
        )

        self.requires("quantlib/1.38", options={"shared": False})

        # aws-lambda-cpp is NOT on ConanCenter.
        # It is built from source in the Containerfile and installed to /usr/local.
        # The handler links against it via system search paths (CMakeLists.txt).

    def build_requirements(self):
        self.tool_requires("cmake/[>=3.25 <4]")

    def layout(self):
        cmake_layout(self, src_folder="src")

    def generate(self):
        CMakeDeps(self).generate()
        CMakeToolchain(self).generate()

    def build(self):
        cmake = CMake(self)
        cmake.configure()
        cmake.build()

    def package(self):
        cmake = CMake(self)
        cmake.install()

    def package_info(self):
        self.cpp_info.libs = ["lambda_cpp26"]

        # Pure re-export components: libs=[] because the real libraries live
        # in the upstream `arrow`/`quantlib` packages. Lets consumers do
        # find_package(lambda_cpp26 REQUIRED COMPONENTS arrow quantlib).
        self.cpp_info.components["arrow"].requires = ["arrow::arrow_static"]
        self.cpp_info.components["arrow"].libs = []

        self.cpp_info.components["quantlib"].requires = ["quantlib::quantlib"]
        self.cpp_info.components["quantlib"].libs = []

    def test(self):
        # RIE-based smoke test lives in tests/ (separate agent's scope).
        pass
