# .devcontainer/Dockerfile (assembled dev container)
# =============================================================================
# Final dev container — takes the combined deps image and adds dev-only tools.
# Used by BOTH:
#
#   1. VSCode "Reopen in Container" with .devcontainer/devcontainer.json
#      (build config — VSCode invokes `docker/podman build -f Dockerfile ..`)
#
#   2. CI: .github/workflows/devcontainer.yml's assemble-devcontainer job
#
# Build time: ~5 min (just dev tool installs). All the heavy lifting
# (GCC compile, Arrow + QuantLib compile) is in the cached deps image.
#
# Build args (all optional — default to :latest):
#   DEPS_TAG       — tag of lambda_cpp26-deps to use
#   REGISTRY_OWNER — ghcr.io owner (default: arekglinka)
#
# To override for local testing:
#   podman build -f .devcontainer/Dockerfile \
#     --build-arg DEPS_TAG=test -t lambda_cpp26-dev:test ..
# =============================================================================

ARG REGISTRY_OWNER=arekglinka
ARG DEPS_TAG=latest
FROM ghcr.io/${REGISTRY_OWNER}/lambda_cpp26-deps:${DEPS_TAG}

# Dev-only packages (NOT in gcc-base/deps because prod doesn't need them).
# clang-tools-extra pulls clang-format/clang-tidy (system clangd 15.x is
# superseded by the pip-installed clangd 22 below).
RUN dnf install -y \
        clang-tools-extra gdb valgrind \
    && dnf clean all

RUN pip3.12 install --no-cache-dir \
        "pyarrow>=15.0" "pytest>=8.0" "clangd>=19"

# Sanity: both libraries must be in the deps cache. Fails fast if the deps
# image is missing expected binaries (e.g., ghcr.io pull fell back to a
# stale tag).
RUN conan list 'arrow/*'    --cache && \
    conan list 'quantlib/*' --cache

WORKDIR /workspace

# VSCode overrides CMD at runtime; this is just a default for `podman run`.
CMD ["sleep", "infinity"]
