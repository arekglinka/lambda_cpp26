"""QuantLib-only consumer — installs transitives + QuantLib 1.38 ONLY
(no arrow). Mirror of arrow-conanfile.py for the quantlib parallel job.
"""
from conan import ConanFile


class QuantLibOnlyConanFile(ConanFile):
    name = "lambda_cpp26-quantlib-only"
    version = "0.1.0"
    settings = "os", "arch", "compiler", "build_type"

    def requirements(self):
        # Same transitives as small-deps-conanfile.py — quantlib only needs
        # boost directly, but we list all transitives so the cache state
        # matches what small-deps built (and what assemble expects).
        self.requires("lz4/1.10.0", options={"shared": False})
        self.requires("zstd/1.5.6", options={"shared": False})
        self.requires("snappy/1.2.1", options={"shared": False})
        self.requires("zlib/1.3.1", options={"shared": False})
        self.requires("brotli/1.1.0", options={"shared": False})
        self.requires("re2/20251105", options={"shared": False})
        self.requires("utf8proc/2.9.0", options={"shared": False})
        self.requires("rapidjson/cci.20250205")
        self.requires("thrift/0.23.0", options={"shared": False})
        self.requires("openssl/3.5.7", options={"shared": False})
        self.requires("boost/1.90.0", options={"header_only": True}, override=True)

        # QuantLib with project's consumer options.
        self.requires("quantlib/1.38", options={"shared": False})

    def build_requirements(self):
        self.tool_requires("cmake/[>=3.25 <4]")
        self.tool_requires("ninja/[>=1.11 <2]")
