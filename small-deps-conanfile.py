"""Small-deps consumer — builds ALL transitive deps of the main project but
NOT arrow/quantlib themselves.

Used by Containerfile.small-deps to produce a base image that Containerfile.arrow
and Containerfile.quantlib inherit FROM. Because both inherit from the same
small-deps image, their conan caches share IDENTICAL transitives — making the
cache merge in the assemble step conflict-free.

Mirrors the deps + options + override from conanfile.py but WITHOUT arrow/18.0.0
and quantlib/1.38. This makes parallel arrow/quantlib builds possible: their
common transitives are pre-built identically here, then each parallel job only
builds its own library (~30 min each) instead of rebuilding transitives.
"""
from conan import ConanFile


class SmallDepsConanFile(ConanFile):
    name = "lambda_cpp26-small-deps"
    version = "0.1.0"
    settings = "os", "arch", "compiler", "build_type"

    def requirements(self):
        # Compression codecs (Parquet + Arrow deps, all static).
        self.requires("lz4/1.10.0", options={"shared": False})
        self.requires("zstd/1.5.6", options={"shared": False})
        self.requires("snappy/1.2.1", options={"shared": False})
        self.requires("zlib/1.3.1", options={"shared": False})
        self.requires("brotli/1.1.0", options={"shared": False})

        # String processing (arrow direct deps).
        self.requires("re2/20251105", options={"shared": False})
        self.requires("utf8proc/2.9.0", options={"shared": False})
        self.requires("rapidjson/cci.20250205")

        # Thrift — Parquet's wire format dependency.
        self.requires("thrift/0.23.0", options={"shared": False})

        # OpenSSL (Arrow crypto/hash).
        self.requires("openssl/3.5.7", options={"shared": False})

        # Boost version override: arrow's recipe pins 1.87.0, but we want 1.90.0
        # across the whole graph. override=True makes this version win even when
        # arrow's recipe is added to the graph (in the arrow-deps job).
        # Header-only to avoid ABI clashes and skip a multi-hour compile.
        self.requires("boost/1.90.0", options={"header_only": True}, override=True)

    def build_requirements(self):
        self.tool_requires("cmake/[>=3.25 <4]")
