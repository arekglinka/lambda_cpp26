"""Arrow-only consumer — installs transitives + Apache Arrow 18.0.0 ONLY
(no quantlib). Used by Containerfile.arrow so the arrow job doesn't waste
~30 min also building quantlib.

The transitive requirements (boost, lz4, etc.) are inherited from the
small-deps parent image's cache. Only arrow itself is a cache miss and
gets built.

Consumer-side options match the project's conanfile.py exactly so the
produced arrow binary has the same package_id the project would produce
in a single-job build. Specifically:
  - csv=False, json=False OVERRIDE arrow recipe defaults (which are True)
  - parquet=True, compute=True, shared=False match recipe defaults
"""
from conan import ConanFile


class ArrowOnlyConanFile(ConanFile):
    name = "lambda_cpp26-arrow-only"
    version = "0.1.0"
    settings = "os", "arch", "compiler", "build_type"

    def requirements(self):
        # Same transitives as small-deps-conanfile.py — kept in sync so the
        # package_ids match what small-deps built (cache hit, no rebuild).
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

        # Arrow with the project's consumer options (matches conanfile.py).
        # csv/json=False OVERRIDE the arrow recipe's defaults of True.
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

    def build_requirements(self):
        self.tool_requires("cmake/[>=3.25 <4]")
        self.tool_requires("ninja/[>=1.11 <2]")
