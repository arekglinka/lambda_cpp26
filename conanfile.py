"""Conan recipe for lambda_cpp26 — a pybind11 C++ extension bundling Apache
Arrow C++ (core + Parquet + Compute) and QuantLib, targeted at AWS Lambda
on Amazon Linux 2023 with CPython 3.12.

Build flow (inside the Podman builder based on lambda/python:3.12):
    conan install . --build=missing -pr:h al2023
    conan build .

The build produces a pybind11 MODULE (.so) — not a static library or exe.
Arrow and QuantLib are built from custom recipes under recipes/ because
ConanCenter's recipes are outdated or have broken defaults.  All other
transitive deps come from ConanCenter.

The Lambda profile (profiles/al2023) disables the Arrow modules Lambda does
not need (those are in the profile's [options] section, not here).
"""

from conan import ConanFile
from conan.tools.cmake import CMakeToolchain, CMake, cmake_layout, CMakeDeps

required_conan_version = ">=2.4"


class LambdaCpp26ConanFile(ConanFile):
    name = "lambda_cpp26"
    version = "0.1.0"
    license = "MIT"
    description = "C++26 pybind11 extension for AWS Lambda — Arrow C++ + QuantLib"
    topics = ("aws-lambda", "cpp26", "arrow", "quantlib", "pybind11", "al2023")
    author = "lambda_cpp26 contributors"
    homepage = "https://github.com/example/lambda_cpp26"
    url = homepage

    package_type = "application"
    settings = "os", "compiler", "build_type", "arch"

    def requirements(self):
        # Compression codecs needed by Parquet (all static).
        self.requires("lz4/1.10.0", options={"shared": False})
        self.requires("zstd/1.5.6", options={"shared": False})
        self.requires("snappy/1.2.1", options={"shared": False})
        self.requires("zlib/1.3.1", options={"shared": False})

        # Thrift — Parquet's wire format dependency.
        self.requires("thrift/0.23.0", options={"shared": False})

        # OpenSSL (Arrow crypto/hash).
        self.requires("openssl/3.5.7", options={"shared": False})

        # Arrow: core + Parquet + Compute ONLY.  Python (PyArrow) handles
        # all cloud I/O.  The modules the recipe defaults to ON are disabled
        # in the Lambda profile's [options] section.
        self.requires(
            "arrow/18.0.0",
            options={
                "shared": False,
                "parquet": True,
                "compute": True,
                "csv": False,
                "json": False,
            },
        )

        self.requires("quantlib/1.38", options={"shared": False})

        # Boost version override: arrow pins 1.87.0, thrift accepts up to
        # 1.90.0.  Force 1.90.0 (header-only) across the graph to resolve
        # the conflict.
        self.requires("boost/1.90.0", options={"header_only": True}, override=True)

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
        # The pybind11 .so is the sole artifact.  CMake installs it via
        # the default LIBRARY destination.
        cmake = CMake(self)
        cmake.install()

    def package_info(self):
        # This recipe builds a standalone extension module, not a library
        # consumed by other Conan packages.
        self.cpp_info.libs = []
